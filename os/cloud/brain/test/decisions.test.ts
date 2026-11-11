// One-tap decisions through the real Worker entry (src/decisions.ts): auth, foreign chat/user ignored, dedupe, idempotent answer, KV shape.
import { env } from 'cloudflare:workers';
import { SELF } from 'cloudflare:test';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { countPending, decisionButtons } from '../src/decisions';

afterEach(() => vi.restoreAllMocks());

const D = (id: string, extra: Record<string, unknown> = {}) => ({ id, question: `Q ${id} <b>?`, why: 'because', default: 'no', cost_if_wrong: 'a PR', kind: 'yes_no', ...extra });
const post = (body: unknown, token: string | null = 'test-ingest-token') =>
  SELF.fetch('https://brain.test/api/decisions', { method: 'POST', headers: token ? { Authorization: `Bearer ${token}` } : {}, body: JSON.stringify(body) });
const get = (qs = '', token: string | null = 'test-ingest-token') => SELF.fetch(`https://brain.test/api/decisions${qs}`, { headers: token ? { Authorization: `Bearer ${token}` } : {} });
const tg = (body: unknown, secret = 'test-tg-secret') => SELF.fetch('https://brain.test/telegram/webhook', { method: 'POST', headers: { 'X-Telegram-Bot-Api-Secret-Token': secret }, body: JSON.stringify(body) });

function mockTelegram() {
  const calls: Array<{ method: string; body: any }> = [];
  let mid = 100;
  vi.spyOn(globalThis, 'fetch').mockImplementation(async (input: RequestInfo | URL, init?: RequestInit) => {
    const m = String(input).split('/').pop()!;
    const body = JSON.parse(String(init?.body ?? '{}'));
    calls.push({ method: m, body });
    return Response.json({ ok: true, result: m === 'sendMessage' ? { message_id: ++mid } : true });
  });
  return calls;
}
const tap = (id: string, code: string, o: { chat?: number; from?: number; mid?: number } = {}) =>
  tg({ callback_query: { id: `cb-${id}${code}`, data: `d:${id}:${code}`, message: { chat: { id: o.chat ?? 4242 }, message_id: o.mid ?? 101 }, from: { id: o.from ?? 4242, username: 'ahmad' } } });

describe('decisions', () => {
  it('rejects a missing or wrong bearer on POST and GET, and a bad body', async () => {
    mockTelegram();
    expect((await post([D('a1')], null)).status).toBe(401);
    expect((await post([D('a1')], 'wrong')).status).toBe(401);
    expect((await get('', null)).status).toBe(401);
    expect((await post([{ id: 'bad id!' }])).status).toBe(400);
    expect((await post([D('a1', { link: 'javascript:alert(1)' })])).status).toBe(400);
    expect((await post(Array.from({ length: 11 }, (_, i) => D(`m${i}`)))).status).toBe(400);
    expect((await get('?status=nope')).status).toBe(400);
  });

  it('stores pending in the documented KV shape, sends one message with buttons, and dedupes by id', async () => {
    const calls = mockTelegram();
    const r = (await (await post([D('shape1'), D('shape1')])).json()) as any;
    expect(r).toEqual({ sent: ['shape1'], duplicate: ['shape1'], failed: [] });
    expect(calls.filter((c) => c.method === 'sendMessage')).toHaveLength(1);
    const sent = calls[0]!.body;
    expect(sent.chat_id).toBe('4242');
    expect(sent.text).toContain('<b>Q shape1 &lt;b&gt;?</b>');
    expect(sent.text).toContain('Default if no answer: no');
    expect(sent.reply_markup.inline_keyboard[0].map((b: any) => b.callback_data)).toEqual(['d:shape1:y', 'd:shape1:n', 'd:shape1:l']);
    const rec = JSON.parse((await env.EVENTS.get('decision:shape1'))!);
    expect(rec).toMatchObject({ id: 'shape1', status: 'pending', kind: 'yes_no', default: 'no', cost_if_wrong: 'a PR', messageId: 101 });
    expect(await env.EVENTS.get('decisionmsg:101')).toBe('shape1');
    // a second call with the same id (pending) never resends
    expect(((await (await post([D('shape1')])).json()) as any).duplicate).toEqual(['shape1']);
    expect(calls.filter((c) => c.method === 'sendMessage')).toHaveLength(1);
  });

  it('non-yes_no kinds get Done/Later plus a URL button for the link', () => {
    const rows = decisionButtons({ id: 'x', kind: 'task', link: 'https://example.com/x' });
    expect(rows[0]!.map((b) => b.callback_data)).toEqual(['d:x:k', 'd:x:l']);
    expect(rows[1]).toEqual([{ text: '🔗 Open', url: 'https://example.com/x' }]);
  });

  it('a failed Telegram send leaves no record so a retry resends', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(new Response('{"ok":false}', { status: 500 }));
    expect(((await (await post([D('fail1')])).json()) as any).failed).toEqual(['fail1']);
    expect(await env.EVENTS.get('decision:fail1')).toBeNull();
  });

  it('a tap from a foreign chat or foreign user is ignored; a wrong secret is 401', async () => {
    const calls = mockTelegram();
    await post([D('own1')]);
    const mid = JSON.parse((await env.EVENTS.get('decision:own1'))!).messageId;
    expect((await tg({}, 'wrong')).status).toBe(401);
    await tap('own1', 'y', { chat: 999, mid });
    await tap('own1', 'y', { from: 777, mid });
    expect(JSON.parse((await env.EVENTS.get('decision:own1'))!).status).toBe('pending');
    expect(calls.some((c) => c.method === 'editMessageText')).toBe(false);
  });

  it('an owner tap records {answer, at, by}, edits the message (buttons removed), and a second tap does nothing', async () => {
    const calls = mockTelegram();
    await post([D('ans1')]);
    const mid = JSON.parse((await env.EVENTS.get('decision:ans1'))!).messageId;
    expect((await tap('ans1', 'y', { mid })).status).toBe(200);
    const rec = JSON.parse((await env.EVENTS.get('decision:ans1'))!);
    expect(rec).toMatchObject({ status: 'answered', answer: 'yes', by: '4242 @ahmad' });
    expect(typeof rec.at).toBe('number');
    const edit = calls.filter((c) => c.method === 'editMessageText');
    expect(edit).toHaveLength(1);
    expect(edit[0]!.body).toMatchObject({ message_id: mid, reply_markup: { inline_keyboard: [] } });
    expect(edit[0]!.body.text).toContain('Answer: yes');
    expect(calls.filter((c) => c.method === 'answerCallbackQuery')).toHaveLength(1);
    // second tap with a different button: still yes, no second edit
    await tap('ans1', 'n', { mid });
    expect(JSON.parse((await env.EVENTS.get('decision:ans1'))!)).toMatchObject({ answer: 'yes', at: rec.at });
    expect(calls.filter((c) => c.method === 'editMessageText')).toHaveLength(1);
    expect(calls.filter((c) => c.method === 'answerCallbackQuery').pop()!.body.text).toBe('already answered: yes');
  });

  it('GET lists by status, and the pending count feeds the digest', async () => {
    mockTelegram();
    await post([D('lst1'), D('lst2')]);
    await tap('lst1', 'n', { mid: JSON.parse((await env.EVENTS.get('decision:lst1'))!).messageId });
    const answered = ((await (await get('?status=answered')).json()) as any).decisions.map((d: any) => d.id);
    const pending = ((await (await get('?status=pending')).json()) as any).decisions.map((d: any) => d.id);
    expect(answered).toContain('lst1');
    expect(answered).not.toContain('lst2');
    expect(pending).toContain('lst2');
    expect(await countPending(env)).toBeGreaterThanOrEqual(1);
  });

  it('a text reply to a decision message becomes its note; a stranger\'s reply does not', async () => {
    mockTelegram();
    await post([D('note1')]);
    const mid = JSON.parse((await env.EVENTS.get('decision:note1'))!).messageId;
    await tg({ message: { chat: { id: 4242 }, from: { id: 777 }, text: 'evil', reply_to_message: { message_id: mid } } });
    expect(JSON.parse((await env.EVENTS.get('decision:note1'))!).note).toBeUndefined();
    await tg({ message: { chat: { id: 4242 }, from: { id: 4242 }, text: 'use the cheaper one', reply_to_message: { message_id: mid } } });
    expect(JSON.parse((await env.EVENTS.get('decision:note1'))!).note).toBe('use the cheaper one');
  });
});
