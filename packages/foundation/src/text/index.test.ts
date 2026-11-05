import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { foldArabic, indexTokens, phoneDigits } from './index';

type V = { in: string; out: string }[];
const v = JSON.parse(readFileSync(new URL('../../../../vectors/arabic.json', import.meta.url), 'utf8')) as { fold: V; index: V; phoneDigits: V };

describe('text vectors (Store fold is canonical, FDN-TEXT-1)', () => {
  it.each(v.fold)('foldArabic %j', (c) => expect(foldArabic(c.in)).toBe(c.out));
  it.each(v.index)('indexTokens %j', (c) => expect(indexTokens(c.in)).toBe(c.out));
  it.each(v.phoneDigits)('phoneDigits %j', (c) => expect(phoneDigits(c.in)).toBe(c.out));
  it('is idempotent', () => {
    for (const c of v.fold) expect(foldArabic(foldArabic(c.in))).toBe(foldArabic(c.in));
  });
});
