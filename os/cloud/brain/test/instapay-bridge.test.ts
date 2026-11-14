// InstaPay bridge through the real Worker entry: signature before parse, caps, replay, owner-only taps, product call signing, retryability.
import { env } from 'cloudflare:workers';
import { SELF } from 'cloudflare:test';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { signBridge, verifyBridge, type DigestItem } from '../../../../packages/foundation/src/instapay-digest';

afterEach(() => vi.restoreAllMocks());
// KV persists across tests in a file; the day/hour claims and replay keys must start empty for each one
beforeEach(async () => {
  for (const prefix of ['instapay:', 'decision']) for (const k of (await env.EVENTS.list({ prefix })).keys) await env.EVENTS.delete(k.name);
});

const SECRET = { store: 'test-bridge-secret-store-0123456789', chat: 'test-bridge-secret-chat-0123456789' };
const item = (n: number, product: 'store' | 'chat' = 'store', over: Record<string, unknown> = {}): DigestItem & { reasons?: string[] } => ({ product, id: `id-${n}`, ownerLabel: `Shop ${n}`, amountMinor: 120050, kind: 'subscription', confirmedAt: 1, ...over });

async function notify(body: unknown, o: { product?: string; secret?: string; ts?: number; sig?: string | null; raw?: string } = {}) {
  const raw = o.raw ?? JSON.stringify(body);
  const ts = o.ts ?? Date.now();
  const product = o.product ?? 'store';
  const sig = o.sig === undefined ? await signBridge(o.secret ?? SECRET[product as 'store'] ?? SECRET.store, raw, ts) : o.sig;
  return SELF.fetch('https://brain.test/api/instapay/notify', { method: 'POST', headers: { 'X-Bridge-Product': product, 'X-Bridge-Ts': String(ts), ...(sig ? { 'X-Bridge-Sig': sig } : {}) }, body: raw });
}
const tg = (body: unknown, secret = 'test-tg-secret') => SELF.fetch('https://brain.test/telegram/webhook', { method: 'POST', headers: { 'X-Telegram-Bot-Api-Secret-Token': secret }, body: JSON.stringify(body) });
const tap = (data: string, o: { chat?: number; from?: number } = {}) => tg({ callback_query: { id: 'cb1', data, message: { chat: { id: o.chat ?? 4242 }, message_id: 7 }, from: { id: o.from ?? 4242 } } });

type Call = { url: string; init: RequestInit | undefined; body: any };
function mockNet(product: (url: string, init?: RequestInit) => Response | Promise<Response> = () => Response.json({ result: 'reverted' })) {
  const calls: Call[] = [];
  let mid = 500;
  vi.spyOn(globalThis, 'fetch').mockImplementation(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input);
    let body: any = null;
    try {
      body = JSON.parse(String(init?.body ?? 'null'));
    } catch {}
    calls.push({ url, init, body });
    if (url.startsWith('https://api.telegram.org/')) return Response.json({ ok: true, result: url.endsWith('/sendMessage') ? { message_id: ++mid } : true });
    return product(url, init);
  });
  return calls;
}
const telegramCalls = (calls: Call[], method: string) => calls.filter((c) => c.url.endsWith(`/${method}`));

describe('POST /api/instapay/notify', () => {
  it('bad or missing signature, unknown product, wrong secret, old timestamp: 401 and nothing sent', async () => {
    const calls = mockNet();
    const body = { kind: 'digest', items: [item(1)] };
    expect((await notify(body, { sig: null })).status).toBe(401);
    expect((await notify(body, { sig: 'a'.repeat(64) })).status).toBe(401);
    expect((await notify(body, { secret: SECRET.chat })).status).toBe(401); // chat's secret does not sign for store
    expect((await notify(body, { product: 'crm' })).status).toBe(401);
    expect((await notify(body, { ts: Date.now() - 6 * 60_000 })).status).toBe(401);
    expect(calls).toHaveLength(0);
  });
  it('signature is checked before parsing: a signed-but-broken body is 400, an unsigned broken body is 401', async () => {
    mockNet();
    expect((await notify(null, { raw: '{not json', sig: 'b'.repeat(64) })).status).toBe(401);
    expect((await notify(null, { raw: '{not json' })).status).toBe(400);
  });
  it('valid digest sends ONE message with one tap button per item', async () => {
    const calls = mockNet();
    const r = await notify({ kind: 'digest', items: [item(1), item(2)] });
    expect(r.status).toBe(200);
    expect(await r.json()).toEqual({ sent: true, items: 2 });
    const sent = telegramCalls(calls, 'sendMessage');
    expect(sent).toHaveLength(1);
    expect(sent[0]!.body.chat_id).toBe('4242');
    expect(sent[0]!.body.reply_markup.inline_keyboard.map((r: any[]) => r[0].callback_data)).toEqual(['ip:s:id-1', 'ip:s:id-2']);
    expect(sent[0]!.body.parse_mode).toBeUndefined(); // plain text: merchant labels cannot inject markup
  });
  it('an empty digest sends nothing and does not use the day claim', async () => {
    const calls = mockNet();
    expect(await (await notify({ kind: 'digest', items: [] })).json()).toEqual({ sent: false, empty: true });
    expect(calls).toHaveLength(0);
    expect((await notify({ kind: 'digest', items: [item(1)] })).status).toBe(200);
  });
  it('a second digest for the same product on the same UTC day is 429, the other product is not', async () => {
    const calls = mockNet();
    expect((await notify({ kind: 'digest', items: [item(1)] })).status).toBe(200);
    expect((await notify({ kind: 'digest', items: [item(2)] })).status).toBe(429);
    expect((await notify({ kind: 'digest', items: [item(3, 'chat')] }, { product: 'chat' })).status).toBe(200);
    expect(telegramCalls(calls, 'sendMessage')).toHaveLength(2);
  });
  it('a failed Telegram send releases the claim so the product retry resends (retried, not lost)', async () => {
    let fail = true;
    vi.spyOn(globalThis, 'fetch').mockImplementation(async () => (fail ? Response.json({ ok: false }, { status: 500 }) : Response.json({ ok: true, result: { message_id: 1 } })));
    expect((await notify({ kind: 'digest', items: [item(1)] })).status).toBe(502);
    fail = false;
    expect((await notify({ kind: 'digest', items: [item(1)] })).status).toBe(200);
  });
  it('an exact replay of a signed request is refused (409) and sends nothing twice', async () => {
    const calls = mockNet();
    const raw = JSON.stringify({ kind: 'waiting', items: [item(1, 'store', { reasons: ['AMOUNT_MISMATCH'] })] });
    const ts = Date.now();
    const sig = await signBridge(SECRET.store, raw, ts);
    expect((await notify(null, { raw, ts, sig })).status).toBe(200);
    expect((await notify(null, { raw, ts, sig })).status).toBe(409);
    expect(telegramCalls(calls, 'sendMessage')).toHaveLength(1);
  });
  it('waiting: reasons shown, no buttons, hourly cap 20 then 429', async () => {
    const calls = mockNet();
    const mk = (n: number) => notify({ kind: 'waiting', items: [item(n, 'store', { reasons: ['DUPLICATE_IMAGE'] })] });
    expect((await mk(0)).status).toBe(200);
    const m = telegramCalls(calls, 'sendMessage')[0]!.body;
    expect(m.text).toContain('DUPLICATE_IMAGE');
    expect(m.reply_markup).toBeUndefined();
    for (let n = 1; n < 20; n++) expect((await mk(n)).status).toBe(200);
    expect((await mk(99)).status).toBe(429);
    expect(telegramCalls(calls, 'sendMessage')).toHaveLength(20);
  });
  it('rejects items that are not the signing product, not callback-safe, or malformed (400, nothing sent)', async () => {
    const calls = mockNet();
    const bad = [item(1, 'chat'), item(2, 'store', { id: 'a:b' }), item(3, 'store', { amountMinor: 1.5 }), item(4, 'store', { amountMinor: -1 }), { nope: 1 }];
    for (const b of bad) expect((await notify({ kind: 'digest', items: [b] })).status, JSON.stringify(b)).toBe(400);
    expect((await notify({ kind: 'waiting', items: [item(1)] })).status).toBe(400); // waiting needs reasons[]
    expect((await notify({ kind: 'other', items: [] })).status).toBe(400);
    expect(calls).toHaveLength(0);
  });
  it('a product whose secret is not configured gets 503, not a pass', async () => {
    mockNet();
    const saved = (env as any).INSTAPAY_BRIDGE_SECRET_CHAT;
    (env as any).INSTAPAY_BRIDGE_SECRET_CHAT = undefined;
    try {
      expect((await notify({ kind: 'digest', items: [item(1, 'chat')] }, { product: 'chat' })).status).toBe(503);
    } finally {
      (env as any).INSTAPAY_BRIDGE_SECRET_CHAT = saved;
    }
  });
  it('does not touch the OS message budget or the decisions store', async () => {
    mockNet();
    await notify({ kind: 'digest', items: [item(1)] });
    const keys = await env.EVENTS.list({ prefix: 'decision' });
    expect(keys.keys).toHaveLength(0);
  });
});

describe('ip: tap', () => {
  it('owner tap calls the product once with a valid signature and a typed body, and answers "reverted"', async () => {
    const calls = mockNet();
    expect((await tap('ip:s:id-1')).status).toBe(200);
    const prod = calls.filter((c) => !c.url.startsWith('https://api.telegram.org/'));
    expect(prod).toHaveLength(1);
    expect(prod[0]!.url).toBe('https://store-api.test/internal/instapay/auto-confirm/not-received');
    expect(prod[0]!.body).toMatchObject({ id: 'id-1', actor: 'telegram-owner' });
    const h = new Headers(prod[0]!.init!.headers);
    const raw = String(prod[0]!.init!.body);
    expect(await verifyBridge(SECRET.store, raw, Number(h.get('X-Bridge-Ts')), h.get('X-Bridge-Sig')!, Date.now())).toBe(true);
    expect(await verifyBridge(SECRET.chat, raw, Number(h.get('X-Bridge-Ts')), h.get('X-Bridge-Sig')!, Date.now())).toBe(false);
    expect(telegramCalls(calls, 'answerCallbackQuery')[0]!.body.text).toBe('reverted');
  });
  it('chat taps go to the chat endpoint with the chat secret', async () => {
    const calls = mockNet();
    await tap('ip:c:req_9');
    const prod = calls.find((c) => c.url.startsWith('https://chat-api.test/'))!;
    const h = new Headers(prod.init!.headers);
    expect(await verifyBridge(SECRET.chat, String(prod.init!.body), Number(h.get('X-Bridge-Ts')), h.get('X-Bridge-Sig')!, Date.now())).toBe(true);
  });
  it('a tap from a non-owner or a foreign chat is ignored: the product is NOT called', async () => {
    const calls = mockNet();
    await tap('ip:s:id-1', { from: 999 });
    await tap('ip:s:id-1', { chat: 111 });
    expect((await tg({ callback_query: { id: 'x', data: 'ip:s:id-1', message: { chat: { id: 4242 }, message_id: 1 }, from: { id: 4242 } } }, 'wrong')).status).toBe(401);
    expect(calls.filter((c) => !c.url.startsWith('https://api.telegram.org/'))).toHaveLength(0);
  });
  it.each([
    ['already reverted replay', () => Response.json({ result: 'already_reverted' }), 'already reverted'],
    ['409 NOT_AUTO_CONFIRMED', () => Response.json({ code: 'NOT_AUTO_CONFIRMED' }, { status: 409 }), 'refused: NOT_AUTO_CONFIRMED'],
    ['404', () => Response.json({}, { status: 404 }), 'refused: unknown payment'],
    ['401', () => Response.json({}, { status: 401 }), 'refused: bridge signature rejected'],
    ['502', () => Response.json({}, { status: 502 }), 'product unreachable, try again'],
    ['network error', () => { throw new Error('boom'); }, 'product unreachable, try again'],
  ])('%s', async (_n, respond, expected) => {
    const calls = mockNet(respond as any);
    await tap('ip:s:id-1');
    expect(telegramCalls(calls, 'answerCallbackQuery')[0]!.body.text).toBe(expected);
  });
  it('an unreachable product keeps no state: the same tap works on retry', async () => {
    let up = false;
    const calls = mockNet(() => (up ? Response.json({ result: 'reverted' }) : Response.json({}, { status: 503 })));
    await tap('ip:s:id-1');
    up = true;
    await tap('ip:s:id-1');
    const texts = telegramCalls(calls, 'answerCallbackQuery').map((c) => c.body.text);
    expect(texts).toEqual(['product unreachable, try again', 'reverted']);
  });
  it('a malformed ip: callback is "not understood" and calls nothing', async () => {
    const calls = mockNet();
    await tap('ip:s:');
    expect(calls.filter((c) => !c.url.startsWith('https://api.telegram.org/'))).toHaveLength(0);
    expect(telegramCalls(calls, 'answerCallbackQuery')[0]!.body.text).toBe('not understood');
  });
  it('an unconfigured revert URL refuses instead of guessing', async () => {
    const calls = mockNet();
    const saved = (env as any).INSTAPAY_REVERT_URL_STORE;
    (env as any).INSTAPAY_REVERT_URL_STORE = 'http://insecure.test/x';
    try {
      await tap('ip:s:id-1');
    } finally {
      (env as any).INSTAPAY_REVERT_URL_STORE = saved;
    }
    expect(telegramCalls(calls, 'answerCallbackQuery')[0]!.body.text).toBe('refused: bridge not configured');
    expect(calls.filter((c) => !c.url.startsWith('https://api.telegram.org/'))).toHaveLength(0);
  });
  it('decisions taps still work (regression)', async () => {
    const calls = mockNet();
    await SELF.fetch('https://brain.test/api/decisions', { method: 'POST', headers: { Authorization: 'Bearer test-ingest-token' }, body: JSON.stringify([{ id: 'reg1', question: 'q', why: 'w', default: 'd', cost_if_wrong: 'c', kind: 'yes_no' }]) });
    await tg({ callback_query: { id: 'c9', data: 'd:reg1:y', message: { chat: { id: 4242 }, message_id: 501 }, from: { id: 4242 } } });
    expect(telegramCalls(calls, 'answerCallbackQuery').pop()!.body.text).toBe('recorded: yes');
  });
});
