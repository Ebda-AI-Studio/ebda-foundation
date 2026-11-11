// Decisions: approval questions Ahmad answers with ONE TAP in Telegram. The controller session POSTs a list to /api/decisions
// (INGEST_TOKEN); each becomes one Telegram message with inline buttons; the tap arrives through the SAME door as every other button
// (POST /telegram/webhook, delivered by Telegram itself since the brain registers the webhook, X-Telegram-Bot-Api-Secret-Token + chat + owner checks in index.ts) and is
// recorded here. The controller reads answers with GET /api/decisions?status=answered. No new secret, no new Telegram consumer
// (sendMessage, editMessageText, answerCallbackQuery).
//
// KV (binding EVENTS): `decision:<id>` = Decision JSON, list metadata {status} (so listing and counting never read the values);
// `decisionmsg:<telegramMessageId>` = <id> (maps a free-text reply back to its decision). Both expire after 180 days.
import { boundFetch } from './bound-fetch';
import type { Env } from './env';

export type DecisionStatus = 'pending' | 'answered';

export interface Decision {
  id: string;
  question: string;
  why: string;
  default: string;
  cost_if_wrong: string;
  /** yes_no gets Yes/No/Later buttons; any other kind gets Done/Later (+ an Open button when `link` is set) */
  kind: string;
  link?: string;
  status: DecisionStatus;
  createdAt: number;
  messageId?: number;
  /** yes | no | later | done (later is an answer: the controller re-asks under a new id when it wants) */
  answer?: string;
  at?: number;
  /** Telegram user id (and @username when it has one) of the presser */
  by?: string;
  note?: string;
}

export const MAX_PER_CALL = 10;
export const SEND_SPACING_MS = 1000;
const TTL = 180 * 86400;
const ID_RE = /^[\w-]{1,48}$/;
const CODES: Record<string, string> = { y: 'yes', n: 'no', l: 'later', k: 'done' };
const key = (id: string) => `decision:${id}`;

export function validateDraft(d: unknown): string | null {
  if (!d || typeof d !== 'object' || Array.isArray(d)) return 'each decision must be an object';
  const o = d as Record<string, unknown>;
  if (typeof o.id !== 'string' || !ID_RE.test(o.id)) return 'id must match [A-Za-z0-9_-]{1,48}';
  for (const f of ['question', 'why', 'default', 'cost_if_wrong', 'kind'] as const) if (typeof o[f] !== 'string' || !o[f]) return `${f} required (non-empty string)`;
  if ((o.question as string).length > 600 || (o.why as string).length > 1200 || (o.default as string).length > 300 || (o.cost_if_wrong as string).length > 300) return 'text too long';
  if (o.link !== undefined && (typeof o.link !== 'string' || !/^https:\/\/\S+$/.test(o.link) || o.link.length > 500)) return 'link must be an https URL';
  return null;
}

const esc = (s: string) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

export function decisionText(d: Pick<Decision, 'question' | 'why' | 'default' | 'cost_if_wrong'>): string {
  return `<b>${esc(d.question)}</b>\n\n${esc(d.why)}\n\nDefault if no answer: ${esc(d.default)}\nCost if wrong: ${esc(d.cost_if_wrong)}`;
}

export function decisionButtons(d: Pick<Decision, 'id' | 'kind' | 'link'>): Array<Array<{ text: string; callback_data?: string; url?: string }>> {
  const row =
    d.kind === 'yes_no'
      ? [
          { text: '✅ Yes', callback_data: `d:${d.id}:y` },
          { text: '❌ No', callback_data: `d:${d.id}:n` },
          { text: '⏸ Later', callback_data: `d:${d.id}:l` },
        ]
      : [
          { text: '✔️ Done', callback_data: `d:${d.id}:k` },
          { text: '⏸ Later', callback_data: `d:${d.id}:l` },
        ];
  return d.link ? [row, [{ text: '🔗 Open', url: d.link }]] : [row];
}

async function tg(env: Env, method: 'sendMessage' | 'editMessageText', body: unknown): Promise<{ ok: boolean; result?: any }> {
  if (!env.TELEGRAM_BOT_TOKEN) return { ok: false };
  try {
    const url = method === 'sendMessage' ? `https://api.telegram.org/bot${env.TELEGRAM_BOT_TOKEN}/sendMessage` : `https://api.telegram.org/bot${env.TELEGRAM_BOT_TOKEN}/editMessageText`;
    const r = await boundFetch(url, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) });
    const j = (await r.json().catch(() => null)) as { ok?: boolean; result?: any } | null;
    return r.ok && j?.ok !== false ? { ok: true, result: j?.result } : { ok: false };
  } catch {
    return { ok: false };
  }
}

async function save(env: Env, d: Decision): Promise<void> {
  await env.EVENTS.put(key(d.id), JSON.stringify(d), { expirationTtl: TTL, metadata: { status: d.status } });
}

export async function getDecision(env: Env, id: string): Promise<Decision | null> {
  const v = await env.EVENTS.get(key(id));
  if (!v) return null;
  try {
    return JSON.parse(v) as Decision;
  } catch {
    return null;
  }
}

export interface PostResult {
  sent: string[];
  duplicate: string[];
  failed: string[];
}

/** Store + send each new decision (deduped by id, at most MAX_PER_CALL, ~1 message/s). A send that fails leaves no record, so a retry resends it. */
export async function postDecisions(env: Env, list: Array<Record<string, any>>, sleep: (ms: number) => Promise<void> = (ms) => new Promise((r) => setTimeout(r, ms))): Promise<PostResult> {
  const out: PostResult = { sent: [], duplicate: [], failed: [] };
  const seen = new Set<string>();
  let sentAny = false;
  for (const raw of list) {
    const id = raw.id as string;
    if (seen.has(id) || (await env.EVENTS.get(key(id)))) {
      out.duplicate.push(id);
      seen.add(id);
      continue;
    }
    seen.add(id);
    const d: Decision = { id, question: raw.question, why: raw.why, default: raw.default, cost_if_wrong: raw.cost_if_wrong, kind: raw.kind, ...(raw.link ? { link: raw.link } : {}), status: 'pending', createdAt: Date.now() };
    await save(env, d); // claim the id before sending: a concurrent call sees a duplicate, never a second message
    if (sentAny) await sleep(SEND_SPACING_MS);
    sentAny = true;
    const r = await tg(env, 'sendMessage', { chat_id: env.TELEGRAM_CHAT_ID, text: decisionText(d), parse_mode: 'HTML', disable_web_page_preview: true, reply_markup: { inline_keyboard: decisionButtons(d) } });
    const mid = Number(r.result?.message_id);
    if (!r.ok || !Number.isFinite(mid)) {
      await env.EVENTS.delete(key(id));
      out.failed.push(id);
      continue;
    }
    d.messageId = mid;
    await save(env, d);
    await env.EVENTS.put(`decisionmsg:${mid}`, id, { expirationTtl: TTL });
    out.sent.push(id);
  }
  return out;
}

/** A button tap (already authenticated by the webhook: secret + chat + owner). Idempotent: a second tap changes nothing. */
export async function answerDecision(env: Env, id: string, code: string, from: { id?: unknown; username?: unknown } | undefined, now: number = Date.now()): Promise<{ ok: boolean; text: string }> {
  const answer = CODES[code];
  const d = await getDecision(env, id);
  if (!d || !answer) return { ok: false, text: 'unknown decision' };
  if (d.status === 'answered') return { ok: true, text: `already answered: ${d.answer}` };
  d.status = 'answered';
  d.answer = answer;
  d.at = now;
  d.by = `${String(from?.id ?? '')}${from?.username ? ` @${String(from.username)}` : ''}`;
  await save(env, d);
  if (d.messageId) await tg(env, 'editMessageText', { chat_id: env.TELEGRAM_CHAT_ID, message_id: d.messageId, text: `${decisionText(d)}\n\n<b>Answer: ${esc(answer)}</b>`, parse_mode: 'HTML', disable_web_page_preview: true, reply_markup: { inline_keyboard: [] } });
  return { ok: true, text: `recorded: ${answer}` };
}

/** Free text sent as a reply to a decision message becomes its `note` (latest wins). */
export async function noteDecision(env: Env, replyToMessageId: number, text: string): Promise<boolean> {
  const id = await env.EVENTS.get(`decisionmsg:${replyToMessageId}`);
  const d = id ? await getDecision(env, id) : null;
  if (!d) return false;
  d.note = text.slice(0, 2000);
  await save(env, d);
  return true;
}

export async function listDecisions(env: Env, status: string | null, limit = 100): Promise<Decision[]> {
  const out: Decision[] = [];
  let cursor: string | undefined;
  do {
    const page: KVNamespaceListResult<{ status?: string }> = await env.EVENTS.list<{ status?: string }>({ prefix: 'decision:', cursor, limit: 1000 });
    for (const k of page.keys) {
      if (status && k.metadata?.status !== status) continue;
      const d = await getDecision(env, k.name.slice('decision:'.length));
      if (d) out.push(d);
      if (out.length >= limit) return out.sort((a, b) => a.createdAt - b.createdAt);
    }
    cursor = page.list_complete ? undefined : page.cursor;
  } while (cursor);
  return out.sort((a, b) => a.createdAt - b.createdAt);
}

/** Pending count for the digest (reads list metadata only, never the values). */
export async function countPending(env: Env): Promise<number> {
  let n = 0;
  let cursor: string | undefined;
  do {
    const page: KVNamespaceListResult<{ status?: string }> = await env.EVENTS.list<{ status?: string }>({ prefix: 'decision:', cursor, limit: 1000 });
    n += page.keys.filter((k) => k.metadata?.status === 'pending').length;
    cursor = page.list_complete ? undefined : page.cursor;
  } while (cursor);
  return n;
}
