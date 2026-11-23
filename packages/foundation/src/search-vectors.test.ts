import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { escapeLike, indexTokens, indexTokensHamza, searchWordPairs } from './text';
import { highlightSegments } from './web/search/highlight';

const v = JSON.parse(readFileSync(new URL('../../../vectors/arabic-search.json', import.meta.url), 'utf8')) as { cases: Array<{ q: string; text: string; match: boolean }> };
/** The rule both products implement (F7-HAMZA-2): every query word is, in its B form, a prefix of a word of the B index text OR, in its A form, a prefix of a word of the A index text. */
const finds = (q: string, text: string) => {
  const wb = indexTokens(text).split(' ');
  const wa = indexTokensHamza(text).split(' ');
  const pairs = searchWordPairs(q);
  return pairs.length > 0 && pairs.every(([b, a = b]) => wb.some((w) => w.startsWith(b!)) || wa.some((w) => w.startsWith(a!)));
};

describe('shared Arabic search (F7)', () => {
  it('every vector gives the same answer in the Store rule and the Chat rule', () => {
    expect(v.cases.length).toBeGreaterThanOrEqual(35);
    for (const c of v.cases) expect(finds(c.q, c.text), `${c.q} -> ${c.text}`).toBe(c.match);
  });
  it('a vector that matches is also highlighted, in the ORIGINAL spelling', () => {
    for (const c of v.cases.filter((x) => x.match && !/[a-z]/i.test(x.q) && !/[a-z]/i.test(x.text))) {
      const marked = highlightSegments(c.text, c.q).filter((s) => s.match);
      expect(marked.length, `${c.q} -> ${c.text}`).toBeGreaterThan(0);
    }
    expect(highlightSegments('شنطة جلد', 'شنطه').filter((s) => s.match).map((s) => s.text)).toEqual(['شنطة']);
  });
  it('highlights across hamza seats and a collapsed waw in the ORIGINAL spelling (F7-HAMZA-1)', () => {
    const marked = (t: string, q: string) => highlightSegments(t, q).filter((x) => x.match).map((x) => x.text);
    expect(marked('مسؤول الحسابات', 'مسئول')).toEqual(['مسؤول']);
    expect(marked('مسئول الحسابات', 'مسؤول')).toEqual(['مسئول']);
    expect(marked('سؤال عن الشحن', 'سئوال')).toEqual(['سؤال']);
    expect(marked('جَزْمَة', 'جزمه')).toEqual(['جَزْمَة']);
  });
  it('searchWordPairs caps at 8 words and drops empty input; escapeLike escapes % _ \\', () => {
    expect(searchWordPairs('a b c d e f g h i j')).toHaveLength(8);
    expect(searchWordPairs('   ')).toEqual([]);
    expect(escapeLike('100%_off\\')).toBe('100\\%\\_off\\\\');
  });
});
