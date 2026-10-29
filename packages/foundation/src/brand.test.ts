import { describe, expect, it } from 'vitest';
import { BARE_AR, BARE_EN, EBDA, brandName } from './brand';

describe('brand', () => {
  it('names by locale', () => {
    expect(brandName('ar-EG')).toBe(EBDA.nameAr);
    expect(brandName('en')).toBe('Ebda AI Studio');
    expect(brandName(null)).toBe('Ebda AI Studio');
  });
  it('every product is "Ebda <Product>" and never bare', () => {
    for (const p of Object.values(EBDA.products)) {
      expect(p.nameEn).toMatch(/^Ebda \S/);
      expect(BARE_EN.test(p.nameEn)).toBe(false);
    }
  });
  it('the bare-Ebda guards fire on bare names and allow product names', () => {
    expect(BARE_EN.test('Welcome to Ebda')).toBe(true);
    expect(BARE_EN.test('Ebda WhatsApp and Ebda AI Studio')).toBe(false);
    expect(BARE_EN.test('X-Ebda-Signature')).toBe(false);
    expect(BARE_AR.test('مرحبا في إبدا')).toBe(true);
    expect(BARE_AR.test('إبدأ ستور')).toBe(false);
    expect(BARE_AR.test('ابدأ الآن')).toBe(false);
  });
});
