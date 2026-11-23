import { describe, expect, it } from 'vitest';
import { registerScore } from './register';

describe('registerScore', () => {
  it('Egyptian reply scores >= 0.8', () => {
    const r = registerScore('عايز أضيف خصم إزاي؟ هتلاقيه في صفحة الكوبونات', 'ar');
    expect(r.score).toBeGreaterThanOrEqual(0.8);
    expect(r.egyMarkers.length).toBeGreaterThan(0);
  });
  it('MSA reply scores < 0.5 and lists يرجى', () => {
    const r = registerScore('يرجى التوجه إلى صفحة القسائم لإضافة الخصم', 'ar');
    expect(r.score).toBeLessThan(0.5);
    expect(r.msaMarkers).toContain('يرجي'); // folded form of يرجى
  });
  it('an English-first reply to an ar question sets englishFirst', () => {
    expect(registerScore('Open the coupons page. ثم اضغط إضافة', 'ar').englishFirst).toBe(true);
  });
  it('digits and Latin product names do not lower arabicRatio below 0.6', () => {
    expect(registerScore('الكوبون SUMMER10 هيخصم ١٠٪', 'ar').arabicRatio).toBeGreaterThanOrEqual(0.6);
  });
  it('an Arabic reply to an English question scores low', () => {
    expect(registerScore('اضغط على الكوبونات', 'en').score).toBeLessThan(0.5);
    expect(registerScore('Open the coupons page and press Add.', 'en').score).toBe(1);
  });
});
