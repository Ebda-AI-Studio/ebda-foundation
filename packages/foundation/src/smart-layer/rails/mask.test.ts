import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { maskForModel } from './mask';

const v = JSON.parse(readFileSync(new URL('../../../../../vectors/smart-layer-mask.json', import.meta.url), 'utf8')) as { cases: Array<{ in: string; out: string }> };

describe('maskForModel', () => {
  for (const c of v.cases) it(`vector: ${JSON.stringify(c.in)}`, () => expect(maskForModel(c.in)).toBe(c.out));
  it('leaves order numbers, prices and quantities alone', () => {
    const s = 'طلب 1001 بسعر 250.50 جنيه، عايز 3 قطع';
    expect(maskForModel(s)).toBe(s);
  });
  it('a phone split by bidi marks and zero-width joiners is still masked', () => {
    expect(maskForModel('0100‎123‏4567')).toBe('[phone]');
  });
  it('returns an empty string for empty input', () => expect(maskForModel('')).toBe(''));
});
