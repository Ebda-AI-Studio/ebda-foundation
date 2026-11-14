import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { francoToArabic } from './franco';

const v = JSON.parse(readFileSync(new URL('../../../../../vectors/smart-layer-scope.json', import.meta.url), 'utf8')) as { franco: Array<{ in: string; has: string }> };

describe('francoToArabic', () => {
  for (const c of v.franco) it(`vector: ${c.in}`, () => expect(francoToArabic(c.in)).toContain(c.has));
  it('leaves pure Arabic and pure English untouched', () => {
    expect(francoToArabic('ازاي أضيف خصم')).toBe('ازاي أضيف خصم');
    expect(francoToArabic('how do I add a coupon')).toBe('how do I add a coupon');
  });
  it('keeps punctuation and spacing', () => expect(francoToArabic('ezay, a3ml coupon?')).toBe('ازاي, اعمل coupon?'));
});
