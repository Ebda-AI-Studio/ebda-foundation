import { describe, expect, it } from 'vitest';
import { renderReply } from './ui-truth';
import type { HelpHit, RegistryCap, RegistryView } from '../types';

const cap: RegistryCap = { id: 'marketing.coupons', version: 1, status: 'live', policy: 'preview', undo: 'reversible', title: { ar: 'الكوبونات', en: 'Coupons' }, appPaths: ['/stores/[id]/marketing/coupons'], uiLabels: { ar: ['الكوبونات', 'إضافة كوبون'], en: ['Coupons', 'Add coupon'] }, helpArticle: 'coupons', examples: [], area: 'marketing' };
const noPath: RegistryCap = { ...cap, id: 'misc.nopath', title: { ar: 'إعداد', en: 'Setting' }, appPaths: [], uiLabels: { ar: ['إعداد'], en: ['Setting'] } };
const reg: RegistryView = { caps: new Map([[cap.id, cap], [noPath.id, noPath]]), byAppPath: (p) => (p === cap.appPaths[0] ? cap : undefined) };
const hits: HelpHit[] = [{ articleId: 'coupons', title: 'إزاي تضيف كوبون', url: 'https://help.ebda.app/coupons/', appPath: null, text: '# إضافة كود خصم\nخطوات', score: 0.9 }];
const texts = (r: ReturnType<typeof renderReply>) => r.segments.map((s) => (s.kind === 'text' ? s.text : s.kind === 'cap' ? `<${s.label}|${s.appPath}>` : s.kind === 'cite' ? `{${s.title}}` : '')).join('');

describe('renderReply', () => {
  it('[[cap:marketing.coupons]] renders the Arabic label and appPath', () => {
    const r = renderReply('روح على [[cap:marketing.coupons]] وادوس إضافة', reg, 'ar', hits);
    expect(r.segments).toEqual([
      { kind: 'text', text: 'روح على ' },
      { kind: 'cap', capabilityId: 'marketing.coupons', label: 'الكوبونات', appPath: '/stores/[id]/marketing/coupons' },
      { kind: 'text', text: ' وادوس إضافة' },
    ]);
    expect(r.removed).toEqual([]);
  });
  it('English locale uses the English label', () => {
    const r = renderReply('Open [[cap:marketing.coupons]]', reg, 'en', hits);
    expect(r.segments[1]).toMatchObject({ kind: 'cap', label: 'Coupons' });
  });
  it('a capability with no app path renders as plain label text', () => {
    expect(texts(renderReply('شوف [[cap:misc.nopath]]', reg, 'ar', hits))).toBe('شوف إعداد');
  });
  it('[[cap:nope]] is removed', () => {
    const r = renderReply('افتح [[cap:nope]] دلوقتي', reg, 'ar', hits);
    expect(texts(r)).toBe('افتح دلوقتي');
    expect(r.removed).toEqual(['cap:nope']);
  });
  it('[[help:id]] resolves to a cite and an unknown article is removed', () => {
    expect(renderReply('اقرا [[help:coupons]]', reg, 'ar', hits).segments[1]).toEqual({ kind: 'cite', articleId: 'coupons', title: 'إزاي تضيف كوبون', url: 'https://help.ebda.app/coupons/' });
    expect(renderReply('اقرا [[help:ghost]]', reg, 'ar', hits).removed).toEqual(['help:ghost']);
  });
  it('"افتح /stores/x/secret" is removed when no registry appPath matches', () => {
    const r = renderReply('افتح /stores/x/secret', reg, 'ar', hits);
    expect(texts(r)).toBe('افتح');
    expect(r.removed).toEqual(['path:/stores/x/secret']);
  });
  it('a raw path that IS a registry appPath is kept', () => {
    expect(texts(renderReply('افتح /stores/[id]/marketing/coupons', reg, 'ar', hits))).toBe('افتح /stores/[id]/marketing/coupons');
  });
  it('fractions, "و/أو" and 24/7 are not paths', () => {
    const s = 'متاح 24/7 و/أو 10/12 وبـ 1/2';
    expect(texts(renderReply(s, reg, 'ar', hits))).toBe(s);
  });
  it('a quoted button label not in the registry is removed, a real one stays', () => {
    const bad = renderReply('دوس على «حفظ كل التغييرات» وخلاص', reg, 'ar', hits);
    expect(texts(bad)).not.toContain('حفظ كل');
    expect(bad.removed[0]).toMatch(/^label:/);
    expect(texts(renderReply('دوس على «إضافة كوبون» وخلاص', reg, 'ar', hits))).toContain('«إضافة كوبون»');
  });
  it('a quoted label equal to a help heading is accepted', () => {
    expect(texts(renderReply('دوس «إضافة كود خصم»', reg, 'ar', hits))).toContain('«إضافة كود خصم»');
  });
  it('a quoted coupon code with digits is not treated as a button label', () => {
    expect(texts(renderReply('الكود "SUMMER10" شغال', reg, 'ar', hits))).toBe('الكود "SUMMER10" شغال');
  });
  it('marker injection: a model-written fake cap id in a quoted fence is still just an id lookup', () => {
    expect(renderReply('[[cap:marketing.coupons]][[cap:marketing.coupons]]', reg, 'ar', hits).segments.filter((s) => s.kind === 'cap')).toHaveLength(2);
  });
});

describe('renderReply: a removal does not leave a space before punctuation', () => {
  it('an unknown capability marker before a colon', () => {
    const r = renderReply('الخطوات بسيطة [[cap:not.a.cap]]:\n1. افتح', reg, 'ar', hits);
    expect(r.removed).toEqual(['cap:not.a.cap']);
    expect(r.segments).toEqual([{ kind: 'text', text: 'الخطوات بسيطة:\n1. افتح' }]);
  });
  it('text with no removal is left exactly as written', () => {
    const r = renderReply('الخطوات بسيطة :\n1. افتح', reg, 'ar', hits);
    expect(r.segments).toEqual([{ kind: 'text', text: 'الخطوات بسيطة :\n1. افتح' }]);
  });
});
