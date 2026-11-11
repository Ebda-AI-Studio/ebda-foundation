// Telegram policy (memory feedback-os-acts-not-pings): the OS acts first and messages only for
//   (1) a P1 the OS could not heal (once per issue), (2) the outcome of an urgent run (one message per run),
//   (3) a decision only Ahmad can make (options + default + deadline), (4) ONE daily digest of outcomes.
// Budget (controller ruling 4a-I2): a HARD daily ceiling of MESSAGE_BUDGET_PER_DAY (3) normal messages (questions) plus
// URGENT_MESSAGE_BUDGET_PER_DAY (3) urgent-class messages (urgent-outcome, p1-unhealed), so at most 6 a day plus the one
// digest. Unhealed-P1 notices are one per incident fingerprint. A deduped key is never sent twice. Anything over its
// bucket rolls into the next digest.
// Credentials: TELEGRAM_BOT_TOKEN + TELEGRAM_CHAT_ID Worker secrets only.
import { boundFetch } from './bound-fetch';

export type MsgKind = 'urgent-outcome' | 'p1-unhealed' | 'question' | 'digest';

export interface Outgoing {
  dedupeKey: string;
  kind: MsgKind;
  text: string;
  buttons?: Array<{ text: string; data: string }>;
}

export type Admission = 'send' | 'duplicate' | 'defer';

export const URGENT_KINDS: ReadonlySet<MsgKind> = new Set(['urgent-outcome', 'p1-unhealed']);

export interface DayCounts {
  /** normal (non-urgent, non-digest) messages already sent today */
  normal: number;
  /** urgent-class messages already sent today */
  urgent: number;
  digest: boolean;
}

/** Pure admission rule; days are UTC. Total non-digest messages per day <= normalBudget + urgentBudget. */
export function admit(kind: MsgKind, alreadySent: boolean, day: DayCounts, normalBudget: number, urgentBudget: number): Admission {
  if (alreadySent) return 'duplicate';
  if (kind === 'digest') return day.digest ? 'duplicate' : 'send';
  if (URGENT_KINDS.has(kind)) return day.urgent < urgentBudget ? 'send' : 'defer';
  return day.normal < normalBudget ? 'send' : 'defer';
}

/** UTC day key, e.g. 2026-11-05. */
export function dayKey(now: number): string {
  return new Date(now).toISOString().slice(0, 10);
}

const MAX_TEXT = 3500;

export function clip(s: string, n = MAX_TEXT): string {
  return s.length > n ? `${s.slice(0, n - 1)}…` : s;
}

export interface SendResult {
  ok: boolean;
  reason?: string;
  /** HTTP status when Telegram answered (401/403 = the token or chat is gone, 429 = slow down) */
  status?: number;
  /** Telegram's parameters.retry_after on a 429, in ms */
  retryAfterMs?: number;
}

/** Send one plain-text message (no parse_mode, so finding text can never inject markup). */
export async function sendTelegram(token: string | undefined, chatId: string | undefined, msg: Outgoing, fetchImpl: typeof fetch = boundFetch): Promise<SendResult> {
  if (!token || !chatId) return { ok: false, reason: 'telegram not configured (TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID secrets unset)' };
  const body: Record<string, unknown> = { chat_id: chatId, text: clip(msg.text), disable_web_page_preview: true };
  if (msg.buttons?.length) body.reply_markup = { inline_keyboard: [msg.buttons.map((b) => ({ text: b.text, callback_data: b.data.slice(0, 64) }))] };
  try {
    const r = await fetchImpl(`https://api.telegram.org/bot${token}/sendMessage`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(body),
    });
    if (!r.ok) {
      const j = (await r.json().catch(() => null)) as { parameters?: { retry_after?: number } } | null;
      const ra = Number(j?.parameters?.retry_after);
      return { ok: false, status: r.status, reason: `telegram HTTP ${r.status}`, ...(r.status === 429 && Number.isFinite(ra) && ra > 0 ? { retryAfterMs: Math.min(ra, 3600) * 1000 } : {}) };
    }
    const j = (await r.json().catch(() => null)) as { ok?: boolean } | null;
    return j?.ok === false ? { ok: false, reason: 'telegram ok=false' } : { ok: true };
  } catch (e) {
    return { ok: false, reason: `telegram fetch failed: ${(e as Error).message}` };
  }
}

export interface QuestionView {
  id: string;
  text: string;
  options: string[];
  defaultOption: string;
  deadline: number;
  reversible: boolean;
}

export function questionMessage(q: QuestionView): Outgoing {
  const when = new Date(q.deadline).toISOString().replace('T', ' ').slice(0, 16);
  const silence = q.reversible ? `Silence = "${q.defaultOption}" after ${when} UTC.` : `Irreversible: nothing happens until you answer (default "${q.defaultOption}" = do nothing).`;
  return {
    dedupeKey: `q:${q.id}`,
    kind: 'question',
    text: `Ebda OS needs a decision\n\n${q.text}\n\nOptions: ${q.options.join(' / ')}\n${silence}`,
    buttons: q.options.map((o) => ({ text: o === q.defaultOption ? `${o} (default)` : o, data: `q:${q.id}:${o}` })),
  };
}

export interface DigestInput {
  day: string;
  /** jobs the hands finished in the last 24 h (fixed: merged or pr-opened) */
  fixed: number;
  /** findings not yet closed (any lane) */
  open: number;
  /** findings closed in the last 24 h because they were no longer reported or were fixed */
  resolved: number;
  /** why the hands are halted (a halt leads the digest) */
  halted?: string | null;
  /** things only Ahmad can decide, then things still broken; already ordered, one short line each */
  needs: string[];
  /** watchers that are not set up (names only; the dashboard has the detail) */
  notSetUp: string[];
  /** the social block (at most 3 lines) or null */
  social?: string | null;
  dashUrl: string;
}

/** The digest is a glance, not a log: at most DIGEST_MAX_LINES lines and DIGEST_MAX_CHARS characters (test/policy.test.ts pins both). */
export const DIGEST_MAX_LINES = 12;
export const DIGEST_MAX_CHARS = 1400;
export const DIGEST_TOP_ITEMS = 5;
const oneLine = (t: string, n = 110) => {
  const one = t.replace(/\s+/g, ' ').trim();
  return one.length > n ? `${one.slice(0, n - 1)}…` : one;
};

export function digestMessage(d: DigestInput): Outgoing {
  const lines: string[] = [`Ebda OS digest ${d.day}${d.halted ? ` | HANDS HALTED (${oneLine(d.halted, 60)})` : ''}`];
  lines.push(`Fixed ${d.fixed} | Open ${d.open} | Needs you ${d.needs.length} | Resolved ${d.resolved}`);
  for (const t of d.needs.slice(0, DIGEST_TOP_ITEMS)) lines.push(`! ${oneLine(t)}`);
  if (d.notSetUp.length) lines.push(`Not set up: ${oneLine(d.notSetUp.join(', '), 100)}`);
  if (d.social) lines.push(...d.social.split('\n').slice(0, 3).map((l) => oneLine(l, 120)));
  const more = d.needs.length - DIGEST_TOP_ITEMS;
  lines.push(`Full list${more > 0 ? ` (+${more} more)` : ''}: ${d.dashUrl}`);
  return { dedupeKey: `digest:${d.day}`, kind: 'digest', text: lines.join('\n') };
}
