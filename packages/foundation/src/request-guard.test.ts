import { describe, expect, it } from 'vitest';
import { Buckets, FixedWindowLimiter, bodyShapeViolation, checkRequestShape, clientKey, guardShape, rateLimitedResponse, readCapped, type RateLimitStore } from './request-guard';

const L = { maxArrayLength: 3, maxDepth: 2, maxNodes: 10 };
const JSON_RULE = { name: 'api', maxBytes: 100, types: ['application/json'] };

describe('request shape (413 / 415)', () => {
  it('oversize declared body -> 413; wrong type -> 415; ok otherwise', () => {
    expect(checkRequestShape({ contentLength: '101', contentType: 'application/json', hasBody: true }, JSON_RULE)).toEqual({ ok: false, status: 413, code: 'payload_too_large' });
    expect(checkRequestShape({ contentLength: '10', contentType: 'text/plain', hasBody: true }, JSON_RULE)).toEqual({ ok: false, status: 415, code: 'unsupported_media' });
    expect(checkRequestShape({ contentLength: '10', contentType: 'Application/JSON; charset=utf-8', hasBody: true }, JSON_RULE)).toEqual({ ok: true });
    expect(checkRequestShape({ contentLength: '0', contentType: null, hasBody: true }, JSON_RULE)).toEqual({ ok: true });
    expect(checkRequestShape({ contentLength: null, contentType: null, hasBody: false }, JSON_RULE)).toEqual({ ok: true });
    expect(checkRequestShape({ contentLength: '10', contentType: 'x/y', hasBody: true }, { ...JSON_RULE, types: null })).toEqual({ ok: true });
  });
  it('guardShape returns the Response', async () => {
    const big = new Request('http://x/', { method: 'POST', body: 'x'.repeat(200), headers: { 'content-type': 'application/json', 'content-length': '200' } });
    expect(guardShape(big, JSON_RULE)!.status).toBe(413);
    const bad = new Request('http://x/', { method: 'POST', body: 'x', headers: { 'content-type': 'text/plain' } });
    expect(guardShape(bad, JSON_RULE)!.status).toBe(415);
    expect(guardShape(new Request('http://x/', { method: 'POST', body: '{}', headers: { 'content-type': 'application/json' } }), JSON_RULE)).toBeNull();
  });
  it('readCapped counts chunked bytes and refuses past the cap', async () => {
    const mk = (n: number) => new Request('http://x/', { method: 'POST', body: new Uint8Array(n), duplex: 'half' } as RequestInit);
    expect((await readCapped(mk(50), 100))!.byteLength).toBe(50);
    expect(await readCapped(mk(150), 100)).toBeNull();
  });
  it('bodyShapeViolation: array, depth, nodes', () => {
    expect(bodyShapeViolation({ a: [1, 2, 3] }, L)).toBeNull();
    expect(bodyShapeViolation([1, 2, 3, 4], L)).toBe('array too long');
    expect(bodyShapeViolation({ a: { b: { c: {} } } }, L)).toBe('nested too deeply');
    expect(bodyShapeViolation(Array.from({ length: 3 }, () => Array.from({ length: 3 }, () => ({}))), L)).toBe('too many fields');
  });
});

describe('rate limiting', () => {
  it('Buckets: burst then wait, refills', () => {
    const b = new Buckets(1, 2);
    expect(b.take('k', 0)).toBe(0);
    expect(b.take('k', 0)).toBe(0);
    expect(b.take('k', 0)).toBe(1);
    expect(b.take('k', 1000)).toBe(0);
  });
  it('clientKey table: IPv4, mapped, compatible, IPv6 forms, zone, garbage', () => {
    const rows: Array<[string | null, string]> = [
      [null, 'unknown'],
      ['1.2.3.4', '1.2.3.4'],
      [' 1.2.3.4 ', '1.2.3.4'],
      ['::ffff:1.2.3.4', '1.2.3.4'],
      ['::FFFF:1.2.3.4', '1.2.3.4'],
      ['::ffff:0102:0304', '1.2.3.4'],
      ['0:0:0:0:0:ffff:1.2.3.4', '1.2.3.4'],
      ['::1.2.3.4', '1.2.3.4'],
      ['::0102:0304', '1.2.3.4'],
      ['::ffff:5.6.7.8', '5.6.7.8'],
      ['::', '0:0:0:0::/64'],
      ['::1', '0:0:0:0::/64'],
      ['2001:db8:0:1:aaaa::1', '2001:db8:0:1::/64'],
      ['2001:DB8:0:1:bbbb::2', '2001:db8:0:1::/64'],
      ['2001:0db8:0000:0001:0000:0000:0000:0001', '2001:db8:0:1::/64'],
      ['2001:db8::1', '2001:db8:0:0::/64'],
      ['64:ff9b::1.2.3.4', '64:ff9b:0:0::/64'],
      ['fe80::1%eth0', 'fe80:0:0:0::/64'],
      ['1.2.3.4%eth0', '1.2.3.4'],
      ['::ffff:1.2.3.4%eth0', '1.2.3.4'],
      ['not-an-ip', 'raw:not-an-ip'],
      ['1.2.3', 'raw:1.2.3'],
      ['1.2.3.256', 'raw:1.2.3.256'],
      ['01.2.3.4', 'raw:01.2.3.4'],
      ['::ffff:1.2.3', 'raw:::ffff:1.2.3'],
      ['1:2:3:4:5:6:7:8:9', 'raw:1:2:3:4:5:6:7:8:9'],
      ['1::2::3', 'raw:1::2::3'],
      ['2001:db8:0:1:2:3:4:5:6::', 'raw:2001:db8:0:1:2:3:4:5:6::'],
      ['gggg::1', 'raw:gggg::1'],
    ];
    for (const [ip, want] of rows) expect(clientKey(ip), String(ip)).toBe(want);
  });
  it('distinct mapped clients and distinct garbage never share a bucket', () => {
    expect(clientKey('::ffff:1.2.3.4')).not.toBe(clientKey('::ffff:1.2.3.5'));
    expect(clientKey('junk-a')).not.toBe(clientKey('junk-b'));
    expect(clientKey('::ffff:1.2.3.4')).toBe(clientKey('1.2.3.4'));
  });
  const counting = (): RateLimitStore => { const m = new Map<string, number>(); return { async hit(k) { const c = (m.get(k) ?? 0) + 1; m.set(k, c); return { count: c, resetAtMs: 10_000 }; } }; };
  const broken: RateLimitStore = { async hit() { throw new Error('down'); } };
  it('FixedWindowLimiter limits with Retry-After -> 429', async () => {
    const l = new FixedWindowLimiter(counting(), { limit: 2, windowMs: 10_000, failMode: 'closed' });
    expect(await l.check('a', 0)).toEqual({ allowed: true });
    expect(await l.check('a', 0)).toEqual({ allowed: true });
    const v = await l.check('a', 4_000);
    expect(v).toEqual({ allowed: false, retryAfterSec: 6, reason: 'limited' });
    const r = rateLimitedResponse(v)!;
    expect(r.status).toBe(429);
    expect(r.headers.get('retry-after')).toBe('6');
    expect(rateLimitedResponse({ allowed: true })).toBeNull();
  });
  it('store outage: open lets through, closed refuses', async () => {
    expect(await new FixedWindowLimiter(broken, { limit: 1, windowMs: 1000, failMode: 'open' }).check('a')).toEqual({ allowed: true });
    expect(await new FixedWindowLimiter(broken, { limit: 1, windowMs: 1000, failMode: 'closed' }).check('a')).toMatchObject({ allowed: false, reason: 'store_error' });
  });
});
