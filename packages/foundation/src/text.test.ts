import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { foldArabic, indexTokens, phoneDigits } from './text';

const v = JSON.parse(readFileSync(new URL('../../../vectors/arabic.json', import.meta.url), 'utf8')) as { cases: Array<{ in: string; out: string }>; equivalent: string[][]; distinct: string[][] };

describe('text', () => {
  it('foldArabic matches every shared vector', () => {
    expect(v.cases.length).toBe(52);
    for (const c of v.cases) expect(foldArabic(c.in), JSON.stringify(c.in)).toBe(c.out);
  });
  it('equivalent spellings fold to one string; distinct words stay distinct (F7-HAMZA-1)', () => {
    for (const g of v.equivalent) expect(new Set(g.map(foldArabic)).size, g.join(' = ')).toBe(1);
    for (const [a, b] of v.distinct) expect(foldArabic(a!), `${a} != ${b}`).not.toBe(foldArabic(b!));
  });
  it('folding is idempotent on every vector', () => {
    for (const c of v.cases) expect(foldArabic(foldArabic(c.in)), c.in).toBe(foldArabic(c.in));
  });
  it('indexTokens folds and replaces punctuation with a single space', () => {
    expect(indexTokens('أحذية، رياضية!! (جديدة)')).toBe('احذيه رياضيه جديده');
    expect(indexTokens('')).toBe('');
  });
  it('phoneDigits', () => {
    expect(phoneDigits('+٢٠ ١٠٠-١٢٣')).toBe('20100123');
  });
});
