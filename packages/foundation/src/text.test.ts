import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { foldArabic, indexTokens, phoneDigits } from './text';

const v = JSON.parse(readFileSync(new URL('../../../vectors/arabic.json', import.meta.url), 'utf8')) as { cases: Array<{ in: string; out: string }> };

describe('text', () => {
  it('foldArabic matches every shared vector', () => {
    expect(v.cases.length).toBe(35);
    for (const c of v.cases) expect(foldArabic(c.in), JSON.stringify(c.in)).toBe(c.out);
  });
  it('indexTokens folds and replaces punctuation with a single space', () => {
    expect(indexTokens('أحذية، رياضية!! (جديدة)')).toBe('احذيه رياضيه جديده');
    expect(indexTokens('')).toBe('');
  });
  it('phoneDigits', () => {
    expect(phoneDigits('+٢٠ ١٠٠-١٢٣')).toBe('20100123');
  });
});
