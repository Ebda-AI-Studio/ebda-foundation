// The brain is the SINGLE consumer of @EbdaAIStudiobot (Telegram allows one: a webhook XOR polling). Three jobs live here:
//   1. admin: POST /api/telegram/webhook/set | /delete, GET /api/telegram/webhook/info (Bearer INGEST_TOKEN). Output never carries the bot token.
//   2. inbox: the owner's plain messages (not replies to a decision) arrive via POST /telegram/webhook and are stored in KV
//      `inbox:<ms>:<update_id>`; the controller reads GET /api/inbox?since=<ms> and marks them with POST /api/inbox/ack.
//   3. outbound: POST /api/telegram/send {text, document_url | document_base64, filename} -> sendMessage / sendDocument.
// Never polls for updates (that would fight the webhook); test/send-only.test.ts pins that.
import { boundFetch } from './bound-fetch';
import type { Env } from './env';

export const WEBHOOK_URL = 'https://os.ebda.app/telegram/webhook';
export const ALLOWED_UPDATES = ['message', 'callback_query'];
export const MAX_TEXT = 4000;
export const MAX_CAPTION = 1024;
export const MAX_DOC_BYTES = 10 * 1024 * 1024;
export const MAX_SEND_BODY = Math.ceil((MAX_DOC_BYTES * 4) / 3) + 64 * 1024;
export const INBOX_LIST_MAX = 100;
const TTL = 30 * 24 * 3600;

export interface InboxItem {
  id: string;
  text: string;
  at: number;
  message_id: number;
  update_id: number;
  file?: { kind: string; file_id: string; name?: string; mime?: string; size?: number };
  read?: boolean;
}

const json = (b: unknown, status = 200) => Response.json(b, { status });

/** Strip the bot token from anything that leaves the brain. */
export function scrub(env: Env, v: unknown): unknown {
  const t = env.TELEGRAM_BOT_TOKEN;
  const s = JSON.stringify(v ?? null);
  return JSON.parse(t ? s.split(t).join('[redacted]') : s);
}

async function botCall(env: Env, method: string, body: BodyInit | Record<string, unknown>, fetchImpl: typeof fetch = boundFetch): Promise<{ status: number; body: any }> {
  const isForm = body instanceof FormData;
  try {
    const r = await fetchImpl(`https://api.telegram.org/bot${env.TELEGRAM_BOT_TOKEN}/${method}`, {
      method: 'POST',
      ...(isForm ? {} : { headers: { 'content-type': 'application/json' } }),
      body: isForm ? (body as FormData) : JSON.stringify(body),
    });
    return { status: r.status, body: await r.json().catch(() => null) };
  } catch (e) {
    return { status: 502, body: { ok: false, description: `fetch failed: ${(e as Error).message}` } };
  }
}

async function readBody(request: Request, max: number): Promise<any> {
  if (Number(request.headers.get('content-length') ?? 0) > max) throw new Error('too large');
  const t = await request.text();
  if (t.length > max) throw new Error('too large');
  return t ? JSON.parse(t) : {};
}

const ownerId = (env: Env) => String(env.TELEGRAM_OWNER_ID || env.TELEGRAM_CHAT_ID || '');

export function isOwnerMessage(env: Env, msg: any): boolean {
  return !!msg && String(msg.chat?.id ?? '') === String(env.TELEGRAM_CHAT_ID ?? '') && String(msg.from?.id ?? '') === ownerId(env) && ownerId(env) !== '';
}

function fileOf(msg: any): InboxItem['file'] | undefined {
  if (msg.document) return { kind: 'document', file_id: msg.document.file_id, name: msg.document.file_name, mime: msg.document.mime_type, size: msg.document.file_size };
  if (Array.isArray(msg.photo) && msg.photo.length) {
    const p = msg.photo[msg.photo.length - 1];
    return { kind: 'photo', file_id: p.file_id, size: p.file_size };
  }
  for (const k of ['voice', 'audio', 'video', 'video_note']) if (msg[k]) return { kind: k, file_id: msg[k].file_id, name: msg[k].file_name, mime: msg[k].mime_type, size: msg[k].file_size };
  return undefined;
}

const pad = (n: number) => String(n).padStart(13, '0');

/** Called by /telegram/webhook for a non-reply `message`. Foreign chat/user: ignored (returns false). Idempotent per update_id. */
export async function recordInbox(env: Env, update: any, fetchImpl: typeof fetch = boundFetch): Promise<boolean> {
  const msg = update?.message;
  if (!isOwnerMessage(env, msg)) return false;
  const file = fileOf(msg);
  const text = typeof msg.text === 'string' ? msg.text : typeof msg.caption === 'string' ? msg.caption : '';
  if (!text && !file) return false;
  const at = Number(msg.date) > 0 ? Number(msg.date) * 1000 : Date.now();
  const id = `inbox:${pad(at)}:${Number(update.update_id) || 0}`;
  if (await env.EVENTS.get(id)) return true; // Telegram retried the same update
  const item: InboxItem = { id, text: text.slice(0, 8000), at, message_id: Number(msg.message_id), update_id: Number(update.update_id) || 0, ...(file ? { file } : {}) };
  await env.EVENTS.put(id, JSON.stringify(item), { expirationTtl: TTL, metadata: { read: false } });
  if (env.TELEGRAM_INBOX_ACK !== '0' && env.TELEGRAM_BOT_TOKEN) {
    await botCall(env, 'sendMessage', { chat_id: env.TELEGRAM_CHAT_ID, text: 'Got it', reply_to_message_id: item.message_id, disable_notification: true }, fetchImpl);
  }
  return true;
}

export async function listInbox(env: Env, since: number): Promise<InboxItem[]> {
  const out: InboxItem[] = [];
  let cursor: string | undefined;
  do {
    const page = await env.EVENTS.list<{ read?: boolean }>({ prefix: 'inbox:', cursor, limit: 1000 });
    for (const k of page.keys) {
      if (k.metadata?.read) continue;
      const ts = Number(k.name.split(':')[1]);
      if (!(ts > since)) continue;
      const v = await env.EVENTS.get(k.name);
      if (v) out.push(JSON.parse(v) as InboxItem);
      if (out.length >= INBOX_LIST_MAX) return out;
    }
    cursor = page.list_complete ? undefined : page.cursor;
  } while (cursor);
  return out;
}

export async function ackInbox(env: Env, ids: string[]): Promise<{ acked: number; missing: number }> {
  let acked = 0;
  let missing = 0;
  for (const id of ids) {
    const v = await env.EVENTS.get(id);
    if (!v) {
      missing++;
      continue;
    }
    const item = JSON.parse(v) as InboxItem;
    if (!item.read) await env.EVENTS.put(id, JSON.stringify({ ...item, read: true }), { expirationTtl: TTL, metadata: { read: true } });
    acked++;
  }
  return { acked, missing };
}

function b64bytes(s: string): Uint8Array | null {
  try {
    const bin = atob(s);
    const u = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) u[i] = bin.charCodeAt(i);
    return u;
  } catch {
    return null;
  }
}

async function fetchDoc(u: string, fetchImpl: typeof fetch): Promise<{ bytes: Uint8Array } | { error: string }> {
  let url: URL;
  try {
    url = new URL(u);
  } catch {
    return { error: 'document_url invalid' };
  }
  const h = url.hostname;
  if (url.protocol !== 'https:' || h === 'localhost' || /^[\d.]+$/.test(h) || h.includes(':') || h.endsWith('.local') || h.endsWith('.internal')) return { error: 'document_url must be https to a public hostname' };
  const r = await fetchImpl(url.toString(), { redirect: 'error' }).catch(() => null);
  if (!r || !r.ok) return { error: 'document_url fetch failed' };
  if (Number(r.headers.get('content-length') ?? 0) > MAX_DOC_BYTES) return { error: 'document over 10 MB' };
  const buf = new Uint8Array(await r.arrayBuffer());
  return buf.length > MAX_DOC_BYTES ? { error: 'document over 10 MB' } : { bytes: buf };
}

export async function handleSend(request: Request, env: Env, fetchImpl: typeof fetch = boundFetch): Promise<Response> {
  if (!env.TELEGRAM_BOT_TOKEN || !env.TELEGRAM_CHAT_ID) return json({ error: 'telegram not configured' }, 503);
  let b: any;
  try {
    b = await readBody(request, MAX_SEND_BODY);
  } catch {
    return json({ error: 'bad json or body too large' }, 400);
  }
  const text = typeof b?.text === 'string' ? b.text : '';
  const hasDoc = typeof b?.document_url === 'string' || typeof b?.document_base64 === 'string';
  if (!text && !hasDoc) return json({ error: 'text or document required' }, 400);
  if (text.length > MAX_TEXT) return json({ error: `text over ${MAX_TEXT} chars` }, 400);
  if (typeof b?.document_url === 'string' && typeof b?.document_base64 === 'string') return json({ error: 'give document_url or document_base64, not both' }, 400);
  const filename = typeof b?.filename === 'string' && /^[\w][\w .()-]{0,120}$/.test(b.filename) ? b.filename : 'file';
  if (b?.filename !== undefined && filename === 'file' && b.filename !== 'file') return json({ error: 'filename must be 1-121 chars of [A-Za-z0-9_ .()-]' }, 400);
  if (!hasDoc) {
    const r = await botCall(env, 'sendMessage', { chat_id: env.TELEGRAM_CHAT_ID, text, disable_web_page_preview: true }, fetchImpl);
    return r.body?.ok ? json({ ok: true, message_id: r.body.result?.message_id }) : json(scrub(env, { error: 'telegram refused', status: r.status, description: r.body?.description }), 502);
  }
  let bytes: Uint8Array;
  if (typeof b.document_base64 === 'string') {
    if (b.document_base64.length > MAX_SEND_BODY) return json({ error: 'document over 10 MB' }, 413);
    const u = b64bytes(b.document_base64);
    if (!u) return json({ error: 'document_base64 invalid' }, 400);
    if (u.length > MAX_DOC_BYTES) return json({ error: 'document over 10 MB' }, 413);
    bytes = u;
  } else {
    const d = await fetchDoc(b.document_url, fetchImpl);
    if ('error' in d) return json({ error: d.error }, d.error.includes('10 MB') ? 413 : 400);
    bytes = d.bytes;
  }
  if (bytes.length === 0) return json({ error: 'document is empty' }, 400);
  if (text.length > MAX_CAPTION) {
    const m = await botCall(env, 'sendMessage', { chat_id: env.TELEGRAM_CHAT_ID, text, disable_web_page_preview: true }, fetchImpl);
    if (!m.body?.ok) return json(scrub(env, { error: 'telegram refused', status: m.status, description: m.body?.description }), 502);
  }
  const form = new FormData();
  form.set('chat_id', String(env.TELEGRAM_CHAT_ID));
  if (text && text.length <= MAX_CAPTION) form.set('caption', text);
  form.set('document', new Blob([bytes as unknown as ArrayBuffer]), filename);
  const r = await botCall(env, 'sendDocument', form, fetchImpl);
  return r.body?.ok ? json({ ok: true, message_id: r.body.result?.message_id, bytes: bytes.length }) : json(scrub(env, { error: 'telegram refused', status: r.status, description: r.body?.description }), 502);
}

/** /api/telegram/webhook/{set,info,delete} */
export async function handleWebhookAdmin(action: string, method: string, env: Env, fetchImpl: typeof fetch = boundFetch): Promise<Response> {
  if (!env.TELEGRAM_BOT_TOKEN) return json({ error: 'telegram not configured' }, 503);
  if (action === 'info' && method === 'GET') {
    const r = await botCall(env, 'getWebhookInfo', {}, fetchImpl);
    return json(scrub(env, { ok: !!r.body?.ok, info: r.body?.result ?? null, description: r.body?.description }), r.body?.ok ? 200 : 502);
  }
  if (method !== 'POST') return json({ error: 'method not allowed' }, 405);
  if (action === 'set') {
    if (!env.TELEGRAM_WEBHOOK_SECRET) return json({ error: 'TELEGRAM_WEBHOOK_SECRET unset' }, 503);
    const r = await botCall(env, 'setWebhook', { url: WEBHOOK_URL, secret_token: env.TELEGRAM_WEBHOOK_SECRET, allowed_updates: ALLOWED_UPDATES, drop_pending_updates: false }, fetchImpl);
    return json(scrub(env, { ok: !!r.body?.ok, url: WEBHOOK_URL, allowed_updates: ALLOWED_UPDATES, description: r.body?.description }), r.body?.ok ? 200 : 502);
  }
  if (action === 'delete') {
    const r = await botCall(env, 'deleteWebhook', { drop_pending_updates: false }, fetchImpl);
    return json(scrub(env, { ok: !!r.body?.ok, description: r.body?.description }), r.body?.ok ? 200 : 502);
  }
  return json({ error: 'not found' }, 404);
}
