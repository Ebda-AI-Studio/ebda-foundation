import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { asciiDigits, isE164, normaliseE164 } from './index';

const dir = new URL('../../../../vectors/', import.meta.url);
const raw = readFileSync(new URL('phone.json', dir));
const cases = JSON.parse(raw.toString()) as { in: string; e164: string | null }[];

describe('phone vectors (PHONE-2, ebda-whatsapp 3f7878d, sha-pinned)', () => {
  it('vector file is byte-identical to the pinned source', () => {
    expect(createHash('sha256').update(raw).digest('hex')).toBe('f1d99cadf8396fe60d04e4361edb2e46f595bfcaf7a0e0b0a72e2c10fd57009b');
    expect(cases.length).toBe(36);
  });
  it.each(cases)('$in', (c) => expect(normaliseE164(c.in)).toBe(c.e164));
  it('isE164 / asciiDigits', () => {
    expect(isE164('+201001234567')).toBe(true);
    expect(isE164('01001234567')).toBe(false);
    expect(asciiDigits('٠١۲')).toBe('012');
  });
});
