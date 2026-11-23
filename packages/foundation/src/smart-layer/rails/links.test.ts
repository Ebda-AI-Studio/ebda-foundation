import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { allowLinks } from './links';
import type { Segment } from '../types';

const v = JSON.parse(readFileSync(new URL('../../../../../vectors/smart-layer-links.json', import.meta.url), 'utf8')) as { cases: Array<{ in: string; merchant?: string[]; out: string }> };
const flat = (segs: Segment[]) => segs.map((s) => (s.kind === 'text' ? s.text : s.kind === 'link' ? `<${s.href}|${s.text}>` : s.kind === 'cite' ? `{${s.url}|${s.title}}` : `[${s.label}]`)).join('');

describe('allowLinks', () => {
  for (const c of v.cases) it(`vector: ${c.in}`, () => expect(flat(allowLinks([{ kind: 'text', text: c.in }], c.merchant ?? []).segments)).toBe(c.out));
  it('a cite segment with a foreign url degrades to its title', () => {
    const r = allowLinks([{ kind: 'cite', articleId: 'a', title: 'Guide', url: 'https://evil.example/x' }], []);
    expect(flat(r.segments)).toBe('Guide');
    expect(r.removed.length).toBe(1);
  });
  it('a cite segment on help.ebda.app is kept', () => {
    const s: Segment = { kind: 'cite', articleId: 'a', title: 'Guide', url: 'https://help.ebda.app/coupons/' };
    expect(allowLinks([s], []).segments).toEqual([s]);
  });
  it('cap segments pass through untouched', () => {
    const s: Segment = { kind: 'cap', capabilityId: 'x.y', label: 'L', appPath: '/p' };
    expect(allowLinks([s], []).segments).toEqual([s]);
  });
});
