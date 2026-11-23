import { describe, expect, it } from 'vitest';
import { BRIDGE_WINDOW_MS, decodeTap, encodeTap, formatDigest, formatDigestPages, formatEgp, formatWaiting, isEmptyDigest, signBridge, verifyBridge, type DigestItem } from './instapay-digest';

const item = (n: number, over: Partial<DigestItem> = {}): DigestItem => ({ product: 'store', id: `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`, ownerLabel: `Shop ${n}`, amountMinor: 120050, kind: 'subscription', confirmedAt: 0, ...over });
const SECRET = 's'.repeat(32);

describe('digest', () => {
  it('empty digest is detectable so the caller never sends it', () => {
    expect(isEmptyDigest([])).toBe(true);
    expect(isEmptyDigest([item(1)])).toBe(false);
  });
  it('amounts come from integer piastres', () => {
    expect(formatEgp(120050)).toBe('EGP 1,200.50');
    expect(formatEgp(5)).toBe('EGP 0.05');
    expect(formatEgp(100)).toBe('EGP 1.00');
    expect(formatEgp(123456789)).toBe('EGP 1,234,567.89');
    expect(formatEgp(1.5)).toBe('EGP ?');
    expect(formatEgp(-1)).toBe('EGP ?');
  });
  it('every item gets a tap button: 45 items -> 3 pages of 20/20/5, no "+N more" (review M4)', () => {
    const items = Array.from({ length: 45 }, (_, i) => item(i));
    const pages = formatDigestPages(items, Date.UTC(2026, 10, 14));
    expect(pages.map((p) => p.buttons.length)).toEqual([20, 20, 5]);
    expect(pages[0]!.text).toContain('2026-11-14');
    expect(pages[0]!.text).toContain('1/3');
    expect(pages[2]!.text).toContain('3/3');
    expect(pages.some((p) => /\+\d+ more/.test(p.text))).toBe(false);
    const ids = pages.flatMap((p) => p.buttons.map((r) => decodeTap(r[0]!.data)!.id));
    expect(ids).toEqual(items.map((i) => i.id)); // each payment exactly once, in order
    for (const p of pages) expect(p.text.match(/^- /gm)).toHaveLength(p.buttons.length);
  });
  it('20 items is one page; 21 is two; 0 is none', () => {
    expect(formatDigestPages(Array.from({ length: 20 }, (_, i) => item(i)), 0)).toHaveLength(1);
    expect(formatDigestPages(Array.from({ length: 21 }, (_, i) => item(i)), 0)).toHaveLength(2);
    expect(formatDigestPages([], 0)).toHaveLength(0);
  });
  it('formatDigest is the first page only (kept for single-message callers)', () => {
    expect(formatDigest(Array.from({ length: 25 }, (_, i) => item(i)), 0).buttons).toHaveLength(20);
  });
  it('merchant text cannot add lines or control characters', () => {
    const d = formatDigest([item(1, { ownerLabel: 'A\nB\u0007<b>x</b>'.padEnd(80, 'z') })], 0);
    expect(d.text.split('\n').filter((l) => l.startsWith('- '))).toHaveLength(1);
    expect(d.text).not.toMatch(/[\u0000-\u0009]/);
  });
  it('waiting message lists the reasons and has no buttons', () => {
    const w = formatWaiting({ ...item(1), reasons: ['AMOUNT_MISMATCH', 'DUPLICATE_IMAGE'] });
    expect(w.text).toContain('AMOUNT_MISMATCH, DUPLICATE_IMAGE');
    expect(w.buttons).toEqual([]);
  });
});

describe('tap codec', () => {
  it('round trips and stays within 64 bytes', () => {
    for (const p of ['store', 'chat'] as const) {
      const id = p === 'store' ? '00000000-0000-4000-8000-000000000001' : 'req_123';
      const data = encodeTap(p, id);
      expect(new TextEncoder().encode(data).length).toBeLessThanOrEqual(64);
      expect(decodeTap(data)).toEqual({ product: p, id });
    }
  });
  it('rejects other callbacks and malformed ones', () => {
    for (const d of ['d:123:y', 's:abc:a', 'ip:x:1', 'ip:s:', 'ip:s:a b', 'ip:s:' + 'a'.repeat(49), '', 'ip:s:a:b']) expect(decodeTap(d), d).toBeNull();
  });
  it('encode refuses an id that is not callback-safe', () => {
    expect(() => encodeTap('store', 'a:b')).toThrow();
    expect(() => encodeTap('store', 'a'.repeat(49))).toThrow();
  });
});

describe('bridge signature (direction-labelled, review M6)', () => {
  const body = '{"id":"x","actor":"telegram-owner"}';
  const now = 1_800_000_000_000;
  const DIRS = ['notify', 'revert'] as const;
  it('verifies in its own direction, and is a 64-hex HMAC', async () => {
    for (const d of DIRS) {
      const sig = await signBridge(SECRET, body, now, d);
      expect(sig).toMatch(/^[0-9a-f]{64}$/);
      expect(await verifyBridge(SECRET, body, now, sig, now, d)).toBe(true);
    }
  });
  it('matches an independent HMAC-SHA256 over "<direction>.<ts>.<body>"', async () => {
    const { createHmac } = await import('node:crypto');
    for (const d of DIRS) expect(await signBridge('k'.repeat(16), 'b', 1, d)).toBe(createHmac('sha256', 'k'.repeat(16)).update(`${d}.1.b`).digest('hex'));
  });
  it('a signature for one direction never verifies as the other (same secret, same body, same ts)', async () => {
    const n = await signBridge(SECRET, body, now, 'notify');
    const r = await signBridge(SECRET, body, now, 'revert');
    expect(n).not.toBe(r);
    expect(await verifyBridge(SECRET, body, now, n, now, 'revert')).toBe(false);
    expect(await verifyBridge(SECRET, body, now, r, now, 'notify')).toBe(false);
  });
  it('an unknown or missing direction never signs and never verifies', async () => {
    await expect(signBridge(SECRET, body, now, 'other' as any)).rejects.toThrow();
    await expect(signBridge(SECRET, body, now, undefined as any)).rejects.toThrow();
    const sig = await signBridge(SECRET, body, now, 'notify');
    expect(await verifyBridge(SECRET, body, now, sig, now, 'other' as any)).toBe(false);
    expect(await verifyBridge(SECRET, body, now, sig, now, undefined as any)).toBe(false);
  });
  it('tampered body, wrong secret, wrong ts, bad sig all fail', async () => {
    const sig = await signBridge(SECRET, body, now, 'notify');
    expect(await verifyBridge(SECRET, body + ' ', now, sig, now, 'notify')).toBe(false);
    expect(await verifyBridge('t'.repeat(32), body, now, sig, now, 'notify')).toBe(false);
    expect(await verifyBridge(SECRET, body, now + 1, sig, now, 'notify')).toBe(false);
    for (const s of ['', 'zz', sig.toUpperCase(), sig.slice(1), sig + '0']) expect(await verifyBridge(SECRET, body, now, s, now, 'notify')).toBe(false);
  });
  it('window: exactly 5 min passes, 5 min + 1 ms fails, both directions of time', async () => {
    const sig = await signBridge(SECRET, body, now - BRIDGE_WINDOW_MS, 'revert');
    expect(await verifyBridge(SECRET, body, now - BRIDGE_WINDOW_MS, sig, now, 'revert')).toBe(true);
    const old = await signBridge(SECRET, body, now - BRIDGE_WINDOW_MS - 1, 'revert');
    expect(await verifyBridge(SECRET, body, now - BRIDGE_WINDOW_MS - 1, old, now, 'revert')).toBe(false);
    const fut = await signBridge(SECRET, body, now + BRIDGE_WINDOW_MS + 1, 'revert');
    expect(await verifyBridge(SECRET, body, now + BRIDGE_WINDOW_MS + 1, fut, now, 'revert')).toBe(false);
    expect(await verifyBridge(SECRET, body, NaN, sig, now, 'revert')).toBe(false);
  });
  it('a short or empty secret never signs and never verifies', async () => {
    await expect(signBridge('', body, now, 'notify')).rejects.toThrow();
    await expect(signBridge('short', body, now, 'notify')).rejects.toThrow();
    expect(await verifyBridge('', body, now, 'a'.repeat(64), now, 'notify')).toBe(false);
  });
});
