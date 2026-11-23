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

describe('edge trim stays linear on long whitespace (CodeQL js/polynomial-redos)', () => {
  it('trims and collapses correctly', () => {
    expect(foldArabic('   a   b   ')).toBe('a b');
    expect(indexTokens('  hello,, world!!  ')).toBe('hello world');
    expect(foldArabic('   ')).toBe('');
  });

  // Note: SPACES collapses runs before the trim, so the old regex was not reachable-quadratic through this API;
  // this pins the behaviour and the time bound so a future change that trims before collapsing cannot regress.
  it('is fast on 400k characters of whitespace around text', () => {
    const hostile = ' '.repeat(200_000) + 'x' + ' '.repeat(200_000) + 'y';
    const t0 = performance.now();
    expect(foldArabic(hostile)).toBe('x y');
    expect(indexTokens(hostile)).toBe('x y');
    expect(performance.now() - t0).toBeLessThan(500);
  });
});
