// Telegram policy (memory feedback-os-acts-not-pings): the OS acts first and messages only for
//   (1) a P1 the OS could not heal (once per issue), (2) the outcome of an urgent run (one message per run),
//   (3) a decision only Ahmad can make (options + default + deadline), (4) ONE daily digest of outcomes.
// Budget (controller ruling 4a-I2): a HARD daily ceiling of MESSAGE_BUDGET_PER_DAY (3) normal messages (questions) plus
// URGENT_MESSAGE_BUDGET_PER_DAY (3) urgent-class messages (urgent-outcome, p1-unhealed), so at most 6 a day plus the one
// digest. Unhealed-P1 notices are one per incident fingerprint. A deduped key is never sent twice. Anything over its
// bucket rolls into the next digest.
// Credentials: TELEGRAM_BOT_TOKEN + TELEGRAM_CHAT_ID Worker secrets only.

export type MsgKind = 'urgent-outcome' | 'p1-unhealed' | 'usage-starved' | 'question' | 'digest';

export interface Outgoing {
  dedupeKey: string;
  kind: MsgKind;
  text: string;
  buttons?: Array<{ text: string; data: string }>;
}

export type Admission = 'send' | 'duplicate' | 'defer';

export const URGENT_KINDS: ReadonlySet<MsgKind> = new Set(['urgent-outcome', 'p1-unhealed', 'usage-starved']);

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
}

/** Send one plain-text message (no parse_mode, so finding text can never inject markup). */
export async function sendTelegram(token: string | undefined, chatId: string | undefined, msg: Outgoing, fetchImpl: typeof fetch = fetch): Promise<SendResult> {
  if (!token || !chatId) return { ok: false, reason: 'telegram not configured (TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID secrets unset)' };
  const body: Record<string, unknown> = { chat_id: chatId, text: clip(msg.text), disable_web_page_preview: true };
  if (msg.buttons?.length) body.reply_markup = { inline_keyboard: [msg.buttons.map((b) => ({ text: b.text, callback_data: b.data.slice(0, 64) }))] };
  try {
    const r = await fetchImpl(`https://api.telegram.org/bot${token}/sendMessage`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(body),
    });
    if (!r.ok) return { ok: false, reason: `telegram HTTP ${r.status}` };
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
  outcomes: Array<{ title: string; status: string; prUrl?: string | null }>;
  raised24h: number;
  acted24h: number;
  ratio7d: number | null;
  pendingQuestions: Array<{ id: string; text: string; defaultOption: string }>;
  rolledUp: Array<{ text: string; failed: boolean }>;
  osBugs: number;
  usageNote: string | null;
}

export function digestMessage(d: DigestInput): Outgoing {
  const lines: string[] = [`Ebda OS daily digest ${d.day}`];
  if (d.outcomes.length) {
    lines.push('', 'Done:');
    for (const o of d.outcomes.slice(0, 20)) lines.push(`- ${o.status}: ${o.title}${o.prUrl ? ` ${o.prUrl}` : ''}`);
    if (d.outcomes.length > 20) lines.push(`- and ${d.outcomes.length - 20} more (dashboard)`);
  } else {
    lines.push('', 'Done: nothing shipped in the last 24 h.');
  }
  const r24 = d.raised24h ? `${d.acted24h}/${d.raised24h}` : 'no findings';
  lines.push('', `Acted-on: ${r24} in 24 h; 7-day ratio ${d.ratio7d === null ? 'n/a' : `${Math.round(d.ratio7d * 100)}%`}.`);
  if (d.osBugs > 0) lines.push(`OS bug: ${d.osBugs} finding(s) left unacted for more than 24 h (see dashboard).`);
  if (d.usageNote) lines.push(`Hands paused: ${d.usageNote}.`);
  if (d.pendingQuestions.length) {
    lines.push('', 'Waiting for you:');
    for (const q of d.pendingQuestions.slice(0, 10)) lines.push(`- ${q.text} (default "${q.defaultOption}")`);
  }
  if (d.rolledUp.length) {
    lines.push('', 'Rolled up (over budget or not delivered):');
    for (const r of d.rolledUp.slice(0, 10)) lines.push(`- ${r.failed ? '[delivery failed] ' : ''}${r.text.split('\n').slice(0, 2).join(' / ')}`);
  }
  return { dedupeKey: `digest:${d.day}`, kind: 'digest', text: lines.join('\n') };
}
