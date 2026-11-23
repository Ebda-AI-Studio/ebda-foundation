import { describe, expect, it } from 'vitest';
import { createStudioPages, HSTS_VALUE, pickStudioLang, type StudioBrand } from './studio-pages';
import { isOrange } from './tokens';

// A fixture brand with the same shape as a product's BRAND (the Store's satisfies StudioBrand structurally). The byte-for-byte proof that the
// Store's old renderer and this one agree lives in the Store (tests/unit/studio-pages-foundation.test.ts, hashes taken from main before the swap).
const BRAND: StudioBrand = {
  colors: { night: '#0A0B0C', gold: '#B08D57', lift: '#CBA873' },
  domains: { marketing: 'ebda.test', storeApp: 'store.ebda.test', whatsappApp: 'wa.ebda.test', status: 'status.ebda.test', docs: 'docs.ebda.test', help: 'help.ebda.test' },
  company: { shortNameAr: 'ابدأ ستوديو للذكاء الاصطناعي', shortNameEn: 'Ebda AI Studio' },
  supportEmail: 'support@ebda.test',
  contact: { whatsapp: '+20 151 419 1411' },
  comingProducts: [
    { id: 'crm', nameAr: 'ابدأ CRM', nameEn: 'Ebda CRM', shortAr: 'عملاؤك', shortEn: 'Your customers' },
    { id: 'erp', nameAr: 'ابدأ ERP', nameEn: 'Ebda ERP', shortAr: 'المخزون', shortEn: 'Inventory' },
  ],
};
const mark = ({ size = 28 }: { size?: number }) => `<svg data-mark="${size}"></svg>`;
const studio = createStudioPages(BRAND, mark);
const LANGS = ['ar', 'en'] as const;
const main = (html: string) => html.slice(html.indexOf('>', html.indexOf('<main')) + 1, html.indexOf('</main>'));

describe('studio pages (shared 404 shell)', () => {
  it('the 404 is a complete noindex document in the page language and direction, with the help search form', () => {
    for (const lang of LANGS) {
      const html = studio.renderStudioPage({ lang, kind: 'not-found' });
      expect(html.startsWith('<!doctype html>')).toBe(true);
      expect(html).toContain(`<html lang="${lang}" dir="${lang === 'ar' ? 'rtl' : 'ltr'}">`);
      expect(html).toContain('<meta name="robots" content="noindex, nofollow">');
      expect(html).toContain('action="https://help.ebda.test/' + (lang === 'ar' ? '' : 'en/') + 'search/"');
      expect(html).toContain('<script src="https://help.ebda.test/assets/typeahead.js" defer></script>');
      expect(html).toContain('mailto:support@ebda.test');
      expect(html).toContain('https://wa.me/201514191411');
    }
    expect(studio.renderStudioPage({ lang: 'en', kind: 'not-found' })).toContain('The page you&#39;re looking for can&#39;t be found.');
  });
  it('no orange anywhere (night + gold) and no script besides the help typeahead', () => {
    const html = studio.renderStudioPage({ lang: 'ar', kind: 'not-found' });
    expect(html).not.toMatch(/orange/i);
    for (const hex of html.match(/#[0-9A-Fa-f]{6}\b/g) ?? []) expect(isOrange(hex), hex).toBe(false);
    expect([...html.matchAll(/<script[^>]*src="([^"]+)"/g)].map((m) => m[1])).toEqual(['https://help.ebda.test/assets/typeahead.js']);
  });
  it('every coming-soon product shares ONE structure; only the copy differs', () => {
    const shape = (html: string) => [...main(html).matchAll(/<([a-z0-9]+)(?:\s[^>]*?class="([^"]*)")?[^>]*>/g)].map((m) => `${m[1]}${m[2] ? '.' + m[2] : ''}`);
    for (const lang of LANGS) {
      const crm = studio.renderStudioPage({ lang, kind: 'coming-soon', product: 'crm' });
      const erp = studio.renderStudioPage({ lang, kind: 'coming-soon', product: 'erp' });
      expect(shape(crm)).toEqual(shape(erp));
      expect(crm).toContain(lang === 'ar' ? 'ابدأ CRM' : 'Ebda CRM');
      expect(crm).toContain('aria-current="page"');
      expect(crm).not.toContain('typeahead.js');
    }
  });
  it('the reserved page names no product and keeps the search', () => {
    const html = studio.renderStudioPage({ lang: 'en', kind: 'coming-soon', product: 'reserved' });
    expect(html).toContain('This address is reserved by Ebda AI Studio.');
    expect(html).toContain('typeahead.js');
  });
  it('studioHostPlan: coming-soon labels answer 200, reserved labels 200 reserved, live-product aliases 301 to the app, everything else 404', () => {
    expect(studio.studioHostPlan('CRM ')).toEqual({ status: 200, kind: 'coming-soon', product: 'crm' });
    expect(studio.studioHostPlan('hub')).toEqual({ status: 200, kind: 'coming-soon', product: 'reserved' });
    expect(studio.studioHostPlan('whatsapp')).toEqual({ status: 301, kind: 'redirect', host: 'wa.ebda.test' });
    expect(studio.studioHostPlan('chat')).toEqual({ status: 301, kind: 'redirect', host: 'wa.ebda.test' });
    expect(studio.studioHostPlan('nothing-here')).toEqual({ status: 404, kind: 'not-found' });
    expect(studio.STUDIO_COMING_SOON_LABELS).toContain('crm');
    expect(studio.STUDIO_REDIRECT_LABELS).toEqual(['whatsapp', 'chat']);
  });
  it('headers: not cacheable, noindex, HSTS, and a CSP whose only allowances are the help script, indexes and form', () => {
    const h = studio.STUDIO_PAGE_HEADERS;
    expect(h['Cache-Control']).toBe('no-store');
    expect(h['X-Robots-Tag']).toBe('noindex, nofollow');
    expect(h['Strict-Transport-Security']).toBe(HSTS_VALUE);
    expect(h['Content-Security-Policy']).toContain("default-src 'none'");
    expect(h['Content-Security-Policy']).toContain('script-src https://help.ebda.test;');
    expect(h['Content-Security-Policy']).toContain("frame-ancestors 'none'");
  });
  it('pickStudioLang: ?lang= wins, then Accept-Language, Arabic by default', () => {
    expect(pickStudioLang('en-US,en;q=0.9')).toBe('en');
    expect(pickStudioLang('ar-EG')).toBe('ar');
    expect(pickStudioLang('en', 'ar')).toBe('ar');
    expect(pickStudioLang(null)).toBe('ar');
    expect(pickStudioLang('fr', 'xx')).toBe('ar');
  });
  it('escapes brand strings in HTML', () => {
    const evil = createStudioPages({ ...BRAND, supportEmail: 'a"><script>x</script>@b' }, mark);
    expect(evil.renderStudioPage({ lang: 'en', kind: 'not-found' })).not.toContain('<script>x</script>');
  });
});
