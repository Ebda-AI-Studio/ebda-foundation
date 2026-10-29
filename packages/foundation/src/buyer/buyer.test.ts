import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { BUYER_KEY_PROBE_INPUT, buyerKey, buyerKeyProbe } from './index';

const read = (f: string) => JSON.parse(readFileSync(new URL(`../../../../vectors/${f}`, import.meta.url), 'utf8'));

describe('buyer', () => {
  it('buyerKey matches every shared vector', async () => {
    const v = read('buyer-key.json') as { secret: string; cases: Array<{ e164: string; hex: string }> };
    expect(v.cases).toHaveLength(8);
    for (const c of v.cases) expect(await buyerKey(v.secret, c.e164)).toBe(c.hex);
  });
  it('refuses a non-E.164 input', async () => {
    await expect(buyerKey('s', '01001234567')).rejects.toThrow('E.164');
  });
  it('probe vector', async () => {
    const v = read('buyer-key-probe.json') as { secret: string; message: string; vector: string };
    expect(v.message).toBe(BUYER_KEY_PROBE_INPUT);
    expect(await buyerKeyProbe(v.secret)).toBe(v.vector);
  });
});
