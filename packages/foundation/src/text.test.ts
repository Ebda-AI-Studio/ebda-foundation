import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { AR_FOLD_FROM, AR_FOLD_H_FROM, AR_FOLD_H_TO, AR_FOLD_TO, foldArabic, foldArabicHamza, indexTextBoth, indexTokens, indexTokensHamza, phoneDigits, sameSearchTerm, searchTokens, searchTokensHamza, searchWordPairs } from './text';

const v = JSON.parse(readFileSync(new URL('../../../vectors/arabic.json', import.meta.url), 'utf8')) as { cases: Array<{ in: string; out: string }> };

const h = JSON.parse(readFileSync(new URL('../../../vectors/arabic-hamza.json', import.meta.url), 'utf8')) as { cases: Array<[string, string]>; equivalentA: string[][]; sameTerm: string[][]; differentTerm: string[][] };

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
  it('fold B is the ORIGINAL fold: the no-regression set (35 original vectors) still holds, and ئ still folds to ي', () => {
    expect(foldArabic('رائع')).toBe('رايع');
    expect(foldArabic('مسئول')).toBe('مسيول');
    expect(foldArabic('مسؤول')).toBe('مسوول');
    expect(foldArabic('\u2009x\u2009')).toBe('\u2009x\u2009'); // no NFKC in B
  });
  it('fold A matches every hamza vector', () => {
    expect(h.cases.length).toBe(28);
    for (const [i, o] of h.cases) expect(foldArabicHamza(i), JSON.stringify(i)).toBe(o);
  });
  it('fold A: equivalent spellings fold to one string; idempotent', () => {
    for (const g of h.equivalentA) expect(new Set(g.map(foldArabicHamza)).size, g.join(' = ')).toBe(1);
    for (const [i] of h.cases) expect(foldArabicHamza(foldArabicHamza(i)), i).toBe(foldArabicHamza(i));
  });
  it('sameSearchTerm = agree under B OR under A: every old B equivalence survives, hamza seats meet, distinct words stay apart', () => {
    for (const [a, b] of h.sameTerm) expect(sameSearchTerm(a!, b!), `${a} ~ ${b}`).toBe(true);
    for (const [a, b] of h.differentTerm) expect(sameSearchTerm(a!, b!), `${a} !~ ${b}`).toBe(false);
    // no-regression: any two inputs that fold equal under the ORIGINAL vectors' B stay the same term
    for (const c of v.cases) expect(sameSearchTerm(c.in, c.out), c.in).toBe(true);
    // not transitive on purpose
    expect(sameSearchTerm('مسيول', 'مسئول') && sameSearchTerm('مسئول', 'مسؤول') && !sameSearchTerm('مسيول', 'مسؤول')).toBe(true);
  });
  it('word pairs: one form when B and A agree, two when they differ; A alone when NFKC changes the word count', () => {
    expect(searchWordPairs('احذيه رياضيه')).toEqual([['احذيه'], ['رياضيه']]);
    expect(searchWordPairs('سائل مسئول')).toEqual([['سايل', 'ساول'], ['مسيول', 'مسول']]);
    expect(searchWordPairs('a\u2009b')).toEqual([['a'], ['b']]);
    expect(searchTokens('سائل')).toEqual(['سايل']);
    expect(searchTokensHamza('سائل')).toEqual(['ساول']);
  });
  it('index text keeps both forms only when they differ', () => {
    expect(indexTextBoth('شنطة جلد')).toBe(indexTokens('شنطة جلد'));
    expect(indexTextBoth('مسئول الحسابات')).toBe(`${indexTokens('مسئول الحسابات')} ${indexTokensHamza('مسئول الحسابات')}`);
  });
  it('fold A translate strings are B plus ء, aligned 1:1, with ئ and ؤ and ء all mapping to و', () => {
    expect([...AR_FOLD_H_FROM].length).toBe([...AR_FOLD_H_TO].length);
    const m = new Map([...AR_FOLD_H_FROM].map((c, i) => [c, [...AR_FOLD_H_TO][i]!]));
    for (const c of 'ءئؤ') expect(m.get(c), c).toBe('و');
    expect(m.get('ى')).toBe('ي');
    expect([...AR_FOLD_FROM].length).toBe([...AR_FOLD_TO].length);
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
  it('the folds are linear: 10k spaces / 10k و / 10k punctuation stay under 50 ms and trim byte-identically to btrim(x, \' \')', () => {
    const ms = (f: () => unknown) => {
      const t0 = performance.now();
      f();
      return performance.now() - t0;
    };
    for (const i of [' '.repeat(10_000), ' x'.repeat(5_000), 'و'.repeat(10_000), '!'.repeat(10_000), '\u2009'.repeat(10_000), 'ءئؤ'.repeat(3_000)]) {
      expect(ms(() => foldArabic(i))).toBeLessThan(50);
      expect(ms(() => foldArabicHamza(i))).toBeLessThan(50);
      expect(ms(() => indexTokens(i))).toBeLessThan(50);
      expect(ms(() => indexTokensHamza(i))).toBeLessThan(50);
    }
    // edge trim removes ONLY U+0020 (SQL btrim(x, ' ')), after the collapse of [ \t\n\r U+00A0]+
    expect(foldArabic('  \t x \u2009 ')).toBe('x \u2009');
    expect(foldArabicHamza('  \t x \u2009 ')).toBe('x');
    expect(foldArabic(' '.repeat(10_000))).toBe('');
  });
});
