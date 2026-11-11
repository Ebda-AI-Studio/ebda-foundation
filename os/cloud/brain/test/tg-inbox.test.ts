// Brain-owned Telegram: webhook admin (token never leaks), owner inbox, outbound send limits, and a decision tap end to end.
import { env } from 'cloudflare:workers';
import { SELF } from 'cloudflare:test';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { MAX_DOC_BYTES } from '../src/tg-inbox';

afterEach(() => vi.restoreAllMocks());

const B = 'https://brain.test';
const auth = { Authorization: 'Bearer test-ingest-token' };
const api = (path: string, init: RequestInit = {}, token: string | null = 'test-ingest-token') => SELF.fetch(`${B}${path}`, { ...init, headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), ...(init.headers as object) } });
const hook = (body: unknown, secret = 'test-tg-secret') => SELF.fetch(`${B}/telegram/webhook`, { method: 'POST', headers: { 'X-Telegram-Bot-Api-Secret-Token': secret }, body: JSON.stringify(body) });
let uid = 5000;
const text = (t: string, o: { chat?: number; from?: number; date?: number; extra?: object } = {}) => ({ update_id: ++uid, message: { message_id: uid, date: o.date ?? 1_800_000_000 + uid, text: t, chat: { id: o.chat ?? 4242 }, from: { id: o.from ?? 4242 }, ...o.extra } });

function mockTg(reply: (m: string, init?: RequestInit) => any = () => ({ ok: true, result: { message_id: 7 } })) {
  const calls: Array<{ method: string; url: string; body: any; init?: RequestInit }> = [];
  vi.spyOn(globalThis, 'fetch').mockImplementation(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input);
    const method = url.split('/').pop()!;
    const raw = init?.body;
    calls.push({ method, url, body: typeof raw === 'string' ? JSON.parse(raw) : raw, init });
    return Response.json(reply(method, init));
  });
  return calls;
}

describe('webhook admin', () => {
  it('needs the INGEST_TOKEN bearer', async () => {
    mockTg();
    for (const [p, m] of [['/api/telegram/webhook/set', 'POST'], ['/api/telegram/webhook/info', 'GET'], ['/api/telegram/webhook/delete', 'POST']] as const) {
      expect((await api(p, { method: m }, null)).status).toBe(401);
      expect((await api(p, { method: m }, 'wrong')).status).toBe(401);
    }
  });
  it('set registers the brain URL with the secret + allowed updates, and never echoes the bot token or the secret', async () => {
    const calls = mockTg();
    const r = await api('/api/telegram/webhook/set', { method: 'POST' });
    const out = await r.text();
    expect(r.status).toBe(200);
    expect(calls).toHaveLength(1);
    expect(calls[0]!.method).toBe('setWebhook');
    expect(calls[0]!.body).toEqual({ url: 'https://os.ebda.app/telegram/webhook', secret_token: 'test-tg-secret', allowed_updates: ['message', 'callback_query'], drop_pending_updates: false });
    expect(out).not.toContain('test-bot-token');
    expect(out).not.toContain('test-tg-secret');
  });
  it('redacts the token even when Telegram echoes it back (info + failed set)', async () => {
    mockTg((m) => (m === 'getWebhookInfo' ? { ok: true, result: { url: 'https://x/test-bot-token', pending_update_count: 2 } } : { ok: false, description: 'bad token test-bot-token' }));
    const info = await (await api('/api/telegram/webhook/info')).text();
    expect(info).toContain('pending_update_count');
    expect(info).not.toContain('test-bot-token');
    const set = await api('/api/telegram/webhook/set', { method: 'POST' });
    expect(set.status).toBe(502);
    expect(await set.text()).not.toContain('test-bot-token');
  });
  it('delete calls deleteWebhook without dropping pending updates', async () => {
    const calls = mockTg();
    expect((await api('/api/telegram/webhook/delete', { method: 'POST' })).status).toBe(200);
    expect(calls[0]).toMatchObject({ method: 'deleteWebhook', body: { drop_pending_updates: false } });
  });
});

describe('inbox', () => {
  it('stores the owner text, replies Got it, lists since, and ack is idempotent', async () => {
    const calls = mockTg();
    const t0 = 1_800_100_000;
    expect((await hook(text('ship the pdf', { date: t0 }))).status).toBe(200);
    const got = calls.filter((c) => c.method === 'sendMessage');
    expect(got).toHaveLength(1);
    expect(got[0]!.body).toMatchObject({ chat_id: '4242', text: 'Got it' });
    const list = (await (await api(`/api/inbox?since=${t0 * 1000 - 1}`)).json()) as any;
    expect(list.items).toHaveLength(1);
    expect(list.items[0]).toMatchObject({ text: 'ship the pdf', at: t0 * 1000 });
    expect(list.items[0].id).toMatch(/^inbox:\d{13}:\d+$/);
    expect(((await (await api(`/api/inbox?since=${t0 * 1000}`)).json()) as any).items).toHaveLength(0);
    const ids = [list.items[0].id];
    const ack = () => api('/api/inbox/ack', { method: 'POST', body: JSON.stringify({ ids }) });
    expect(await (await ack()).json()).toEqual({ acked: 1, missing: 0 });
    expect(await (await ack()).json()).toEqual({ acked: 1, missing: 0 });
    expect(((await (await api(`/api/inbox?since=${t0 * 1000 - 1}`)).json()) as any).items).toHaveLength(0);
    expect(await (await api('/api/inbox/ack', { method: 'POST', body: JSON.stringify({ ids: ['inbox:0000000000001:1'] }) })).json()).toEqual({ acked: 0, missing: 1 });
    expect((await api('/api/inbox/ack', { method: 'POST', body: JSON.stringify({ ids: ['decision:x'] }) })).status).toBe(400);
  });
  it('a Telegram retry of the same update is stored once and acknowledged once', async () => {
    const calls = mockTg();
    const u = text('once', { date: 1_800_200_000 });
    await hook(u);
    await hook(u);
    expect(calls.filter((c) => c.method === 'sendMessage')).toHaveLength(1);
    expect(((await (await api(`/api/inbox?since=${1_800_200_000_000 - 1}`)).json()) as any).items).toHaveLength(1);
  });
  it('stores file info for a document with a caption', async () => {
    mockTg();
    await hook(text('', { date: 1_800_300_000, extra: { text: undefined, caption: 'see this', document: { file_id: 'F1', file_name: 'a.pdf', mime_type: 'application/pdf', file_size: 99 } } }));
    const it = (((await (await api(`/api/inbox?since=${1_800_300_000_000 - 1}`)).json()) as any).items as any[])[0];
    expect(it).toMatchObject({ text: 'see this', file: { kind: 'document', file_id: 'F1', name: 'a.pdf', size: 99 } });
  });
  it('ignores foreign chats, foreign users, a wrong secret, and empty messages', async () => {
    const calls = mockTg();
    const d = 1_800_400_000;
    await hook(text('from a stranger chat', { chat: 999, date: d }));
    await hook(text('from a group member', { from: 777, date: d }));
    expect((await hook(text('wrong secret', { date: d }), 'nope')).status).toBe(401);
    await hook({ update_id: ++uid, message: { message_id: 1, date: d, chat: { id: 4242 }, from: { id: 4242 }, sticker: {} } });
    expect(calls).toHaveLength(0);
    expect(((await (await api(`/api/inbox?since=${d * 1000 - 1}`)).json()) as any).items).toHaveLength(0);
  });
  it('a reply to a decision stays a note and is not an inbox item', async () => {
    mockTg();
    await env.EVENTS.put('decisionmsg:555', 'dec1');
    await env.EVENTS.put('decision:dec1', JSON.stringify({ id: 'dec1', status: 'pending' }));
    const d = 1_800_500_000;
    await hook(text('because reasons', { date: d, extra: { reply_to_message: { message_id: 555 } } }));
    expect(((await (await api(`/api/inbox?since=${d * 1000 - 1}`)).json()) as any).items).toHaveLength(0);
    expect(JSON.parse((await env.EVENTS.get('decision:dec1'))!).note).toBe('because reasons');
  });
  it('inbox reads need the bearer', async () => {
    expect((await api('/api/inbox', {}, null)).status).toBe(401);
    expect((await api('/api/inbox/ack', { method: 'POST', body: '{}' }, null)).status).toBe(401);
  });
});

describe('decision tap through the brain webhook', () => {
  it('ask -> tap -> answered, with the tap acknowledged to Telegram', async () => {
    const calls = mockTg((m) => ({ ok: true, result: m === 'sendMessage' ? { message_id: 321 } : true }));
    const ask = await api('/api/decisions', { method: 'POST', body: JSON.stringify([{ id: 'e2e1', question: 'go?', why: 'w', default: 'no', cost_if_wrong: 'c', kind: 'yes_no' }]) });
    expect(((await ask.json()) as any).sent).toEqual(['e2e1']);
    const r = await hook({ update_id: ++uid, callback_query: { id: 'cbx', data: 'd:e2e1:y', message: { chat: { id: 4242 }, message_id: 321 }, from: { id: 4242, username: 'ahmad' } } });
    expect(r.status).toBe(200);
    expect(calls.some((c) => c.method === 'answerCallbackQuery' && c.body.callback_query_id === 'cbx')).toBe(true);
    const done = ((await (await api('/api/decisions?status=answered')).json()) as any).decisions;
    expect(done.find((d: any) => d.id === 'e2e1')).toMatchObject({ answer: 'yes' });
  });
});

describe('send', () => {
  const send = (b: unknown, token: string | null = 'test-ingest-token') => api('/api/telegram/send', { method: 'POST', body: JSON.stringify(b) }, token);
  it('needs the bearer; rejects empty, over-long text, bad filename, both document sources', async () => {
    mockTg();
    expect((await send({ text: 'x' }, null)).status).toBe(401);
    expect((await send({})).status).toBe(400);
    expect((await send({ text: 'a'.repeat(4001) })).status).toBe(400);
    expect((await send({ document_base64: 'AAAA', filename: '../x' })).status).toBe(400);
    expect((await send({ document_base64: 'AAAA', document_url: 'https://example.com/a' })).status).toBe(400);
  });
  it('sends 4000 chars of text to the configured chat', async () => {
    const calls = mockTg();
    const r = await send({ text: 'a'.repeat(4000) });
    expect(r.status).toBe(200);
    expect(calls[0]).toMatchObject({ method: 'sendMessage', body: { chat_id: '4242' } });
    expect(calls[0]!.body.text).toHaveLength(4000);
  });
  it('sends a base64 document as multipart sendDocument with caption + filename', async () => {
    const calls = mockTg();
    const r = await send({ text: 'the pdf', document_base64: btoa('%PDF-1.4 hello'), filename: 'report.pdf' });
    expect(r.status).toBe(200);
    expect(calls[0]!.method).toBe('sendDocument');
    const f = calls[0]!.body as FormData;
    expect(f.get('chat_id')).toBe('4242');
    expect(f.get('caption')).toBe('the pdf');
    expect((f.get('document') as File).name).toBe('report.pdf');
  });
  it('rejects a document over 10 MB (base64 and url) before calling Telegram', async () => {
    const calls = mockTg();
    const big = btoa('a'.repeat(MAX_DOC_BYTES + 1));
    expect((await send({ document_base64: big, filename: 'big.bin' })).status).toBe(413);
    expect(calls).toHaveLength(0);
    const f = vi.spyOn(globalThis, 'fetch').mockImplementation(async () => new Response(new Uint8Array(MAX_DOC_BYTES + 1)));
    expect((await send({ document_url: 'https://example.com/big.bin', filename: 'big.bin' })).status).toBe(413);
    f.mockRestore();
  });
  it('refuses a non-https or private document_url', async () => {
    mockTg();
    for (const u of ['http://example.com/a', 'https://localhost/a', 'https://127.0.0.1/a', 'https://[::1]/a']) expect((await send({ document_url: u })).status).toBe(400);
  });
  it('never leaks the bot token when Telegram refuses', async () => {
    mockTg(() => ({ ok: false, description: 'Unauthorized test-bot-token' }));
    const r = await send({ text: 'hi' });
    expect(r.status).toBe(502);
    expect(await r.text()).not.toContain('test-bot-token');
  });
});
