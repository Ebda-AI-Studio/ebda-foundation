// InstaPay bridge (money path): the daily digest + immediate "waiting" messages of the InstaPay auto-confirm feature, and the one-tap
// "not received" revert. It rides the SAME Telegram door as decisions (POST /telegram/webhook, owner + chat checks in index.ts): the
// brain stays the single consumer of @EbdaAIStudiobot, nothing here polls, and the Bot API methods used stay sendMessage + answerCallbackQuery.
// Unlike a decision (a recorded answer the controller reads later), a tap here must ACT: the brain calls the owning product's
// HMAC-signed revert endpoint, which is idempotent. The brain keeps no payment state, only a tiny audit + rate-limit trail in KV.
//
//   POST /api/instapay/notify   headers X-Bridge-Product (store|chat), X-Bridge-Ts (epoch ms), X-Bridge-Sig = HMAC-SHA256 hex over `${ts}.${rawBody}`
//                               with the product's secret (INSTAPAY_BRIDGE_SECRET_STORE|CHAT), checked BEFORE any parsing.
//                               body { kind: 'digest' | 'waiting', items: DigestItem[] (+ reasons[] for waiting) }
// Secrets (Worker secrets): INSTAPAY_BRIDGE_SECRET_STORE, INSTAPAY_BRIDGE_SECRET_CHAT, INSTAPAY_REVERT_URL_STORE, INSTAPAY_REVERT_URL_CHAT.
import { boundFetch } from './bound-fetch';
import { tg } from './decisions';
import type { Env } from './env';
import { decodeTap, encodeTap, formatDigest, formatWaiting, isEmptyDigest, signBridge, verifyBridge, type DigestItem } from '../../../../packages/foundation/src/instapay-digest';

const MAX_BODY = 64 * 1024;
export const MAX_DIGEST_ITEMS_ACCEPTED = 200;
export const MAX_WAITING_PER_CALL = 5;
export const WAITING_PER_HOUR = 20;
const TAP_TIMEOUT_MS = 8000;
const SIG_TTL = 600;
const AUDIT_TTL = 180 * 86400;
const json = (data: unknown, status = 200) => new Response(JSON.stringify(data), { status, headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' } });

type Product = 'store' | 'chat';
const secretOf = (env: Env, p: Product) => (p === 'store' ? env.INSTAPAY_BRIDGE_SECRET_STORE : env.INSTAPAY_BRIDGE_SECRET_CHAT);
const revertUrlOf = (env: Env, p: Product) => (p === 'store' ? env.INSTAPAY_REVERT_URL_STORE : env.INSTAPAY_REVERT_URL_CHAT);

function validItem(x: unknown, product: Product, withReasons: boolean): (DigestItem & { reasons: string[] }) | null {
  if (!x || typeof x !== 'object' || Array.isArray(x)) return null;
  const o = x as Record<string, unknown>;
  if (o.product !== product) return null; // a product can only speak for itself
  if (typeof o.id !== 'string' || typeof o.ownerLabel !== 'string' || typeof o.kind !== 'string' || o.ownerLabel.length > 200 || o.kind.length > 100) return null;
  if (typeof o.amountMinor !== 'number' || !Number.isSafeInteger(o.amountMinor) || o.amountMinor < 0) return null;
  if (typeof o.confirmedAt !== 'number' || !Number.isFinite(o.confirmedAt)) return null;
  try {
    encodeTap(product, o.id); // id must be callback-safe
  } catch {
    return null;
  }
  let reasons: string[] = [];
  if (withReasons) {
    if (!Array.isArray(o.reasons) || o.reasons.length > 20 || o.reasons.some((r) => typeof r !== 'string' || r.length > 60)) return null;
    reasons = o.reasons as string[];
  }
  return { product, id: o.id, ownerLabel: o.ownerLabel, amountMinor: o.amountMinor, kind: o.kind, confirmedAt: o.confirmedAt, reasons };
}

export async function handleInstapayNotify(request: Request, env: Env, now: number = Date.now()): Promise<Response> {
  if (request.method !== 'POST') return json({ error: 'method not allowed' }, 405);
  const product = request.headers.get('X-Bridge-Product');
  if (product !== 'store' && product !== 'chat') return json({ error: 'unauthorized' }, 401);
  const secret = secretOf(env, product);
  if (!secret) return json({ error: 'bridge not configured for this product' }, 503);
  const len = Number(request.headers.get('content-length') ?? 0);
  if (len > MAX_BODY) return json({ error: 'too large' }, 413);
  const raw = await request.text();
  if (raw.length > MAX_BODY) return json({ error: 'too large' }, 413);
  const ts = Number(request.headers.get('X-Bridge-Ts'));
  const sig = request.headers.get('X-Bridge-Sig') ?? '';
  if (!(await verifyBridge(secret, raw, ts, sig, now))) return json({ error: 'unauthorized' }, 401); // BEFORE any parsing effect
  // a signed request cannot be replayed inside the 5-minute window
  const sigKey = `instapay:sig:${sig}`;
  if (await env.EVENTS.get(sigKey)) return json({ error: 'replayed' }, 409);
  let body: any;
  try {
    body = JSON.parse(raw);
  } catch {
    return json({ error: 'bad json' }, 400);
  }
  const kind = body?.kind;
  if ((kind !== 'digest' && kind !== 'waiting') || !Array.isArray(body.items)) return json({ error: 'kind digest|waiting and items[] required' }, 400);
  if (!env.TELEGRAM_BOT_TOKEN || !env.TELEGRAM_CHAT_ID) return json({ error: 'telegram not configured' }, 503);
  const items = body.items.map((x: unknown) => validItem(x, product, kind === 'waiting'));
  if (items.some((x: unknown) => x === null)) return json({ error: 'invalid item' }, 400);
  await env.EVENTS.put(sigKey, '1', { expirationTtl: SIG_TTL });
  const list = items as Array<DigestItem & { reasons: string[] }>;

  if (kind === 'digest') {
    if (list.length > MAX_DIGEST_ITEMS_ACCEPTED) return json({ error: `at most ${MAX_DIGEST_ITEMS_ACCEPTED} items` }, 400);
    if (isEmptyDigest(list)) return json({ sent: false, empty: true });
    const dayKey = `instapay:digest:${product}:${new Date(now).toISOString().slice(0, 10)}`;
    if (await env.EVENTS.get(dayKey)) return json({ error: 'digest already sent today' }, 429);
    await env.EVENTS.put(dayKey, '1', { expirationTtl: 2 * 86400 }); // claim before sending (a concurrent call sees it)
    const d = formatDigest(list, now);
    const r = await tg(env, 'sendMessage', { chat_id: env.TELEGRAM_CHAT_ID, text: d.text, disable_web_page_preview: true, reply_markup: { inline_keyboard: d.buttons.map((row) => row.map((b) => ({ text: b.text, callback_data: b.data }))) } });
    if (!r.ok) {
      await env.EVENTS.delete(dayKey); // a failed send leaves no claim, so the product's retry resends it
      await env.EVENTS.delete(sigKey);
      return json({ error: 'telegram send failed' }, 502);
    }
    return json({ sent: true, items: list.length });
  }

  if (list.length < 1 || list.length > MAX_WAITING_PER_CALL) return json({ error: `waiting takes 1-${MAX_WAITING_PER_CALL} items` }, 400);
  const hourKey = `instapay:waiting:${product}:${new Date(now).toISOString().slice(0, 13)}`;
  const used = Number((await env.EVENTS.get(hourKey)) ?? 0) || 0;
  if (used + list.length > WAITING_PER_HOUR) {
    await env.EVENTS.delete(sigKey);
    return json({ error: 'waiting-message hourly cap reached' }, 429);
  }
  await env.EVENTS.put(hourKey, String(used + list.length), { expirationTtl: 2 * 3600 });
  let sent = 0;
  for (const it of list) {
    const w = formatWaiting(it);
    const r = await tg(env, 'sendMessage', { chat_id: env.TELEGRAM_CHAT_ID, text: w.text, disable_web_page_preview: true });
    if (r.ok) sent++;
  }
  if (sent < list.length) {
    await env.EVENTS.delete(sigKey);
    return json({ error: 'telegram send failed', sent }, 502);
  }
  return json({ sent: true, items: sent });
}

/** A "not received" tap (index.ts already checked secret + chat + owner). Returns the answerCallbackQuery text. Never throws. */
export async function handleInstapayTap(env: Env, data: string, now: number = Date.now(), fetchImpl: typeof fetch = boundFetch): Promise<string | null> {
  const tap = decodeTap(data);
  if (!tap) return null;
  const secret = secretOf(env, tap.product);
  const url = revertUrlOf(env, tap.product);
  if (!secret || !url || !/^https:\/\/\S+$/.test(url)) return 'refused: bridge not configured';
  const body = JSON.stringify({ id: tap.id, actor: 'telegram-owner', tappedAt: now });
  let text: string;
  try {
    const sig = await signBridge(secret, body, now);
    const res = await fetchImpl(url, { method: 'POST', headers: { 'content-type': 'application/json', 'X-Bridge-Ts': String(now), 'X-Bridge-Sig': sig }, body, signal: AbortSignal.timeout(TAP_TIMEOUT_MS) });
    const j = (await res.json().catch(() => null)) as { result?: unknown; code?: unknown; error?: unknown } | null;
    if (res.ok) text = j?.result === 'already_reverted' || j?.result === 'already reverted' ? 'already reverted' : 'reverted';
    else if (res.status === 401) text = 'refused: bridge signature rejected';
    else if (res.status === 404) text = 'refused: unknown payment';
    else if (res.status === 409) text = `refused: ${String(j?.code ?? j?.error ?? 'conflict').slice(0, 60)}`;
    else text = 'product unreachable, try again'; // 5xx: nothing is kept, the tap is retryable
  } catch {
    text = 'product unreachable, try again';
  }
  await env.EVENTS.put(`instapay:tap:${tap.product}:${tap.id}:${now}`, text, { expirationTtl: AUDIT_TTL }).catch(() => undefined);
  return text;
}
