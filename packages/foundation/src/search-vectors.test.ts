import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { escapeLike, indexTokens, searchTokens } from './text';
import { highlightSegments } from './web/search/highlight';

const v = JSON.parse(readFileSync(new URL('../../../vectors/arabic-search.json', import.meta.url), 'utf8')) as { cases: Array<{ q: string; text: string; match: boolean }> };
/** The rule both products implement: every query word is a prefix of some indexed word. */
const finds = (q: string, text: string) => {
  const words = indexTokens(text).split(' ');
  const toks = searchTokens(q);
  return toks.length > 0 && toks.every((t) => words.some((w) => w.startsWith(t)));
};

describe('shared Arabic search (F7)', () => {
  it('every vector gives the same answer in the Store rule and the Chat rule', () => {
    expect(v.cases.length).toBeGreaterThanOrEqual(20);
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
  it('searchTokens caps at 8 words and drops punctuation-only input; escapeLike escapes % _ \\', () => {
    expect(searchTokens('a b c d e f g h i j')).toHaveLength(8);
    expect(searchTokens('   ')).toEqual([]);
    expect(escapeLike('100%_off\\')).toBe('100\\%\\_off\\\\');
  });
});
