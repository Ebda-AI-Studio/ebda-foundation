import { describe, expect, it } from 'vitest';
import { BRAND, BARE_AR, BARE_EN, PRODUCTS, brandFrom, brandName, findBareBrand, getProduct, isBrandHost, productName } from './index';

describe('brand', () => {
  it('names the studio and every product with the Ebda prefix, never bare', () => {
    expect(brandName('ar-EG')).toBe(BRAND.nameAr);
    expect(brandName()).toBe('Ebda AI Studio');
    for (const p of PRODUCTS) {
      expect(p.nameEn).toMatch(/^Ebda [A-Z]/);
      expect(findBareBrand(p.nameEn)).toEqual([]);
      expect(findBareBrand(p.nameAr)).toEqual([]);
      expect(p.host).toBe(`${p.id}.ebda.app`);
    }
  });
  it('productName / getProduct throw on an unknown id', () => {
    expect(productName('store', 'ar')).toBe('ابدأ ستور');
    expect(() => getProduct('nope')).toThrow();
  });
  it('isBrandHost', () => {
    expect(isBrandHost('Shop.ebda.app:8787')).toBe(true);
    expect(isBrandHost('ebda.app')).toBe(true);
    expect(isBrandHost('evilebda.app')).toBe(false);
    expect(isBrandHost(null)).toBe(false);
  });
  it('brandFrom refuses the bare brand', () => {
    expect(() => brandFrom(' ebda ')).toThrow();
    expect(brandFrom('Ebda Store')).toBe('Ebda Store <no-reply@ebda.app>');
  });
  it('bare-brand regexes flag bare uses and accept product uses', () => {
    expect(BARE_EN.test('Welcome to Ebda')).toBe(true);
    expect(BARE_EN.test('Welcome to Ebda Store')).toBe(false);
    expect(BARE_EN.test('X-Ebda-Signature')).toBe(false);
    expect(BARE_AR.test('مرحبا في إبدأ')).toBe(true);
    expect(BARE_AR.test('إبدأ ستور')).toBe(false);
  });
});
