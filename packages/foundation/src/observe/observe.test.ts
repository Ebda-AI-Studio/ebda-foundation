import { describe, expect, it, vi } from 'vitest';
import { readFileSync } from 'node:fs';
import { DENIED_KEY, buildAlertText, errClass, maskEmail, maskPhone, maskPhones, memoryThrottle, redactEmails, redactFreeText, safeMessage, scrubEvent, scrubRequestUrl, telegramAlert, type EventLike } from './index';

type V = { maskPhones: [string, string][]; redactEmails: [string, string][]; scrubRequestUrl: [string, string | null][]; safeMessage: [string, string][] };
const v = JSON.parse(readFileSync(new URL('../../../../vectors/redaction.json', import.meta.url), 'utf8')) as V;

describe('redaction vectors', () => {
  it('maskPhones', () => { for (const [i, o] of v.maskPhones) expect(maskPhones(i), JSON.stringify(i)).toBe(o); });
  it('redactEmails', () => { for (const [i, o] of v.redactEmails) expect(redactEmails(i), JSON.stringify(i)).toBe(o); });
  it('scrubRequestUrl', () => { for (const [i, o] of v.scrubRequestUrl) expect(scrubRequestUrl(i) ?? null, i).toBe(o); });
  it('safeMessage', () => { for (const [i, o] of v.safeMessage) expect(safeMessage(new Error(i)), i).toBe(o); });
});

describe('masks', () => {
  it('maskPhones keeps undefined and passes through the empty string', () => {
    expect(maskPhones(undefined)).toBeUndefined();
    expect(maskPhones('')).toBe('');
  });
  it('single-value masks (Store)', () => {
    expect(maskPhone('+201012345678')).toBe('+201 ****5678');
    expect(maskPhone('٠١٠١٢٣٤٥٦٧٨')).toBe('****5678'); // Arabic-Indic digits are stripped by \D in the Store mask; documented in the PR body
    expect(maskEmail('ahmad@gmail.com')).toBe('a***@gmail.com');
  });
  it('redactFreeText now hides Arabic-Indic phones too but still spares ISO dates and order refs', () => {
    expect(redactFreeText('كلمني على ٠١٠١٢٣٤٥٦٧٨ بعد العصر')).toBe('كلمني على [phone] بعد العصر');
    expect(redactFreeText('موعد 2026-09-30 طلب ORD-20260930-001')).toBe('موعد 2026-09-30 طلب ORD-20260930-001');
    expect(redactFreeText('call 9999 8888')).toBe('call [phone]');
  });
  it('safeMessage is bounded and errClass never echoes text', () => {
    expect(safeMessage('x'.repeat(500)).length).toBe(200);
    expect(errClass(Object.assign(new RangeError('01012345678'), { code: 'E_BAD' }))).toBe('RangeError:E_BAD');
    expect(errClass('01012345678')).toBe('string');
    expect(errClass(null)).toBe('null');
  });
});

describe('scrubEvent (strictest of Store + Chat)', () => {
  const event = (): EventLike => ({
    message: 'تعذر الإرسال إلى منى علي 01012345678',
    transaction: 'GET /contacts/201012345678',
    user: { id: '1', username: 'منى علي' },
    extra: { name: 'محمد أحمد' },
    tags: { phone: '01012345678' },
    contexts: { x: 1 },
    spans: [{ description: 'SELECT * FROM t WHERE phone=01012345678' }],
    request: {
      url: 'https://chat.ebda.app/api/contacts/%D9%A0%D9%A1%D9%A0%D9%A1%D9%A2%D9%A3%D9%A4%D9%A5%D9%A6%D9%A7%D9%A8/x?q=01012345678',
      data: { body: 'مرحبا' }, cookies: 'a=b', query_string: 'q=01012345678',
      headers: { 'User-Agent': 'x', Authorization: 'Bearer s', Cookie: 'c', 'x-ebda-client-ip': '1.2.3.4', 'CF-Ray': 'r' },
    },
    exception: { values: [{ type: 'Error', value: 'bad number 01112223334 for mona@example.com' }] },
    breadcrumbs: [{ message: 'sent to +201112223334', data: { to: '01112223334' }, category: 'x' }],
  });
  it('drops every identity-bearing field and masks what stays', () => {
    const out = scrubEvent(event());
    expect(out.user).toBeUndefined(); expect(out.extra).toBeUndefined(); expect(out.tags).toBeUndefined(); expect(out.contexts).toBeUndefined(); expect(out.spans).toBeUndefined();
    expect(out.request).toEqual({ url: 'https://chat.ebda.app/api/contacts/[phone]/x', headers: { 'User-Agent': 'x', 'CF-Ray': 'r' } });
    expect(out.message).toBe('تعذر الإرسال إلى منى علي [phone]');
    expect(out.transaction).toBe('GET /contacts/[phone]');
    expect(out.exception?.values?.[0]?.value).toBe('bad number [phone] for [email]');
    expect(out.breadcrumbs).toEqual([{ category: 'x', message: 'sent to [phone]' }]);
  });
  it('does not mutate a frozen event and leaves no 8+ digit run in the output', () => {
    const e = Object.freeze(event());
    const out = scrubEvent(e);
    expect(out).not.toBe(e);
    expect(e.user).toBeDefined();
    expect(JSON.stringify(out)).not.toMatch(/\d{8,}/);
  });
  it('an unparseable url is removed, not kept raw', () => {
    expect(scrubEvent({ request: { url: 'not a url' } }).request?.url).toBeUndefined();
  });
});

describe('telegramAlert', () => {
  const base = { product: 'Ebda Chat', level: 'p0' as const, title: 'instapay_confirmed_not_granted' };
  it('builds the shared header: product first, level + scope, env, masked body/fields, denied keys dropped', () => {
    const t = buildAlertText({
      ...base, scope: 'workspace', scopeLine: 'abcd1234…', env: 'production', runbook: 'https://docs/x.md',
      fields: { orderId: 'o_1', customerName: 'محمد أحمد', phone: '01012345678', note: 'اتصل 01012345678', ids: ['a', 'b'], deep: { a: 1 } },
      body: 'العميل منى على 01112223334', context: { name: 'منى', ref: 'r1', note: 'x@y.com', apiKey: 'k-123', nested: { authToken: 't' } },
    });
    expect(t.split('\n').slice(0, 4)).toEqual(['🔴 Ebda Chat: instapay_confirmed_not_granted', '[P0 WORKSPACE]', 'workspace=abcd1234…', 'env=production · runbook=https://docs/x.md']);
    expect(t).toContain('orderId=o_1'); expect(t).toContain('ids=a,b'); expect(t).toContain('note=اتصل [phone]');
    expect(t).not.toContain('محمد'); expect(t).toContain('"name": "منى"'); // context keeps product-authored keys (an error name, a store name) expect(t).not.toMatch(/\d{8,}/); expect(t).not.toContain('x@y.com');
    expect(t).toContain('العميل منى على [phone]'); // free-text Arabic names cannot be detected: only structured denied keys drop them (PR body: residual)
    expect(t).not.toContain('deep'); expect(t).not.toContain('k-123'); expect(t).toContain('"ref": "r1"');
  });
  it('platform scope has no scope line; info is blue; text is capped at 4096', () => {
    expect(buildAlertText({ ...base, level: 'info', scopeLine: 'ignored' }).split('\n').slice(0, 2)).toEqual(['🔵 Ebda Chat: instapay_confirmed_not_granted', '[INFO PLATFORM]']);
    expect(buildAlertText({ ...base, context: { big: 'z'.repeat(9000) } }).length).toBeLessThanOrEqual(4096);
  });
  it('skips without a token or chat, sends once, and never throws', async () => {
    const fetchOk = vi.fn(async () => new Response('{}', { status: 200 }));
    expect(await telegramAlert({ fetch: fetchOk }, base)).toBe('skipped');
    expect(fetchOk).not.toHaveBeenCalled();
    expect(await telegramAlert({ token: 't', chatId: 'c', fetch: fetchOk }, base)).toBe('sent');
    const [url, init] = fetchOk.mock.calls[0] as unknown as [string, RequestInit];
    expect(url).toBe('https://api.telegram.org/bott/sendMessage');
    expect(JSON.parse(String(init.body))).toMatchObject({ chat_id: 'c' });
    expect(await telegramAlert({ token: 't', chatId: 'c', fetch: vi.fn(async () => new Response('no', { status: 500 })) }, base)).toBe('failed');
    expect(await telegramAlert({ token: 't', chatId: 'c', fetch: vi.fn(async () => { throw new Error('boom 01012345678'); }) }, base)).toBe('failed');
  });
  it('reports a rejection and a throw to onError, sends disable_web_page_preview when asked, and survives a throwing onError', async () => {
    const seen: unknown[] = [];
    const onError = (i: unknown) => { seen.push(i); };
    const bad = vi.fn(async () => new Response('chat not found', { status: 400 }));
    expect(await telegramAlert({ token: 't', chatId: 'c', fetch: bad as unknown as typeof fetch, onError, disableWebPagePreview: true }, base)).toBe('failed');
    expect(JSON.parse(String((bad.mock.calls[0] as unknown as [string, RequestInit])[1].body))).toMatchObject({ disable_web_page_preview: true });
    expect(await telegramAlert({ token: 't', chatId: 'c', fetch: vi.fn(async () => { throw new Error('x'); }) as unknown as typeof fetch, onError }, base)).toBe('failed');
    expect(seen).toEqual([{ status: 400, detail: 'chat not found' }, { err: expect.any(Error) }]);
    expect(await telegramAlert({ token: 't', chatId: 'c', fetch: bad as unknown as typeof fetch, onError: () => { throw new Error('logger down'); } }, base)).toBe('failed');
    const plain = vi.fn(async () => new Response('{}'));
    await telegramAlert({ token: 't', chatId: 'c', fetch: plain as unknown as typeof fetch }, base);
    expect(JSON.parse(String((plain.mock.calls[0] as unknown as [string, RequestInit])[1].body))).not.toHaveProperty('disable_web_page_preview');
  });
  it('times out a fetch that never settles', async () => {
    const hang = vi.fn((_u: string, init?: RequestInit) => new Promise<Response>((_r, rej) => init?.signal?.addEventListener('abort', () => rej(new Error('aborted')))));
    expect(await telegramAlert({ token: 't', chatId: 'c', fetch: hang as unknown as typeof fetch, timeoutMs: 20 }, base)).toBe('failed');
  });
  it('throttles identical alerts and states how many it swallowed', async () => {
    let now = 0;
    const throttle = memoryThrottle(() => now);
    const bodies: string[] = [];
    const f = vi.fn(async (_u: string, init?: RequestInit) => { bodies.push(JSON.parse(String(init?.body)).text); return new Response('{}'); });
    const cfg = { token: 't', chatId: 'c', fetch: f as unknown as typeof fetch };
    expect(await telegramAlert(cfg, base, { throttle })).toBe('sent');
    expect(await telegramAlert(cfg, base, { throttle })).toBe('throttled');
    expect(await telegramAlert(cfg, base, { throttle })).toBe('throttled');
    expect(await telegramAlert(cfg, { ...base, title: 'other' }, { throttle })).toBe('sent');
    now = 10 * 60_000 + 1;
    expect(await telegramAlert(cfg, base, { throttle })).toBe('sent');
    expect(bodies.at(-1)).toContain('(suppressed 2 more since the last alert)');
  });
  it('a throttle store that throws still never throws out of telegramAlert', async () => {
    const throttle = { claim: () => { throw new Error('redis down'); } };
    expect(await telegramAlert({ token: 't', chatId: 'c', fetch: vi.fn() as unknown as typeof fetch }, base, { throttle })).toBe('failed');
  });
  it('DENIED_KEY covers the keys that carry people and credentials', () => {
    for (const k of ['name', 'customerName', 'phone', 'waId', 'wa_id', 'botToken', 'password', 'authorization', 'email', 'body']) expect(DENIED_KEY.test(k), k).toBe(true);
    for (const k of ['orderId', 'workspace', 'error', 'count']) expect(DENIED_KEY.test(k), k).toBe(false);
  });
});
