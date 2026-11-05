import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { buyerKey } from './index';

const raw = readFileSync(new URL('../../../../vectors/buyer-key.json', import.meta.url));
const v = JSON.parse(raw.toString()) as { secret: string; cases: { e164: string; hex: string }[] };

describe('buyerKey vectors (ebda-whatsapp 3f7878d, sha-pinned)', () => {
  it('vector file is byte-identical to the pinned source', () => {
    expect(createHash('sha256').update(raw).digest('hex')).toBe('00c47c95622dc2516d3c86d492e609fc0f8659b5645416fd076634e245c62ca1');
    expect(v.cases.length).toBe(8);
  });
  it.each(v.cases)('$e164', async (c) => expect(await buyerKey(v.secret, c.e164)).toBe(c.hex));
  it('refuses a non-E.164 input', async () => {
    await expect(buyerKey('s', '01001234567')).rejects.toThrow();
  });
});
