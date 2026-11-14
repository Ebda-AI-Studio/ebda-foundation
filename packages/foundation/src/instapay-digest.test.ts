import { describe, expect, it } from 'vitest';
import { BRIDGE_WINDOW_MS, decodeTap, encodeTap, formatDigest, formatEgp, formatWaiting, isEmptyDigest, signBridge, verifyBridge, type DigestItem } from './instapay-digest';

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
  it('25 items -> 20 shown + "+5 more", one button row each', () => {
    const d = formatDigest(Array.from({ length: 25 }, (_, i) => item(i)), Date.UTC(2026, 10, 14));
    expect(d.text).toContain('+5 more');
    expect(d.text).toContain('2026-11-14');
    expect(d.buttons).toHaveLength(20);
    expect(d.text.match(/^- /gm)).toHaveLength(20);
    for (const row of d.buttons) expect(decodeTap(row[0]!.data)).not.toBeNull();
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

describe('bridge signature', () => {
  const body = '{"id":"x","actor":"telegram-owner"}';
  const now = 1_800_000_000_000;
  it('verifies, and is a 64-hex HMAC', async () => {
    const sig = await signBridge(SECRET, body, now);
    expect(sig).toMatch(/^[0-9a-f]{64}$/);
    expect(await verifyBridge(SECRET, body, now, sig, now)).toBe(true);
  });
  it('matches an independent HMAC-SHA256 over "<ts>.<body>"', async () => {
    const { createHmac } = await import('node:crypto');
    expect(await signBridge('k'.repeat(16), 'b', 1)).toBe(createHmac('sha256', 'k'.repeat(16)).update('1.b').digest('hex'));
  });
  it('tampered body, wrong secret, wrong ts, bad sig all fail', async () => {
    const sig = await signBridge(SECRET, body, now);
    expect(await verifyBridge(SECRET, body + ' ', now, sig, now)).toBe(false);
    expect(await verifyBridge('t'.repeat(32), body, now, sig, now)).toBe(false);
    expect(await verifyBridge(SECRET, body, now + 1, sig, now)).toBe(false);
    for (const s of ['', 'zz', sig.toUpperCase(), sig.slice(1), sig + '0']) expect(await verifyBridge(SECRET, body, now, s, now)).toBe(false);
  });
  it('window: exactly 5 min passes, 5 min + 1 ms fails, both directions', async () => {
    const sig = await signBridge(SECRET, body, now - BRIDGE_WINDOW_MS);
    expect(await verifyBridge(SECRET, body, now - BRIDGE_WINDOW_MS, sig, now)).toBe(true);
    const old = await signBridge(SECRET, body, now - BRIDGE_WINDOW_MS - 1);
    expect(await verifyBridge(SECRET, body, now - BRIDGE_WINDOW_MS - 1, old, now)).toBe(false);
    const fut = await signBridge(SECRET, body, now + BRIDGE_WINDOW_MS + 1);
    expect(await verifyBridge(SECRET, body, now + BRIDGE_WINDOW_MS + 1, fut, now)).toBe(false);
    expect(await verifyBridge(SECRET, body, NaN, sig, now)).toBe(false);
  });
  it('a short or empty secret never signs and never verifies', async () => {
    await expect(signBridge('', body, now)).rejects.toThrow();
    await expect(signBridge('short', body, now)).rejects.toThrow();
    expect(await verifyBridge('', body, now, 'a'.repeat(64), now)).toBe(false);
  });
});
