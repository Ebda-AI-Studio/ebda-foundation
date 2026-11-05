import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { asciiDigits, isE164, isEgyptianNational, normaliseE164 } from './phone';

const cases = JSON.parse(readFileSync(new URL('../../../vectors/phone.json', import.meta.url), 'utf8')) as Array<{ in: string; e164: string | null }>;

describe('phone', () => {
  it('matches every shared vector', () => {
    expect(cases.length).toBeGreaterThanOrEqual(30);
    for (const c of cases) expect(normaliseE164(c.in), c.in).toBe(c.e164);
  });
  it('rejects foreign numbers without a prefix, keeps them with one', () => {
    expect(normaliseE164('07911123456')).toBeNull();
    expect(normaliseE164('+447911123456')).toBe('+447911123456');
    expect(normaliseE164('00447911123456')).toBe('+447911123456');
  });
  it('helpers', () => {
    expect(asciiDigits('٠١۲')).toBe('012');
    expect(isE164('+201001234567')).toBe(true);
    expect(isE164('201001234567')).toBe(false);
    expect(isEgyptianNational('0221234567')).toBe(true);
    expect(isEgyptianNational('0900000000')).toBe(false);
  });
});
