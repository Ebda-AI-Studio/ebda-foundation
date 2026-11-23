import { describe, expect, it } from 'vitest';
import { checkBindingClaims } from './binding-claims';
import type { BindingSource } from '../types';

const plan = (key: string, price: string): BindingSource => ({ kind: 'plan', key, text: { ar: `باقة ${key}`, en: `${key} plan` }, values: [price, key] });

describe('checkBindingClaims', () => {
  it('matches ١٠٠ in reply against 100 in source', () => {
    const r = checkBindingClaims('الباقة بـ ١٠٠ جنيه في الشهر.', [plan('Starter', '100')], []);
    expect(r.removed).toEqual([]);
    expect(r.text).toBe('الباقة بـ ١٠٠ جنيه في الشهر.');
  });
  it('"باقة Growth بـ 499 جنيه" with source value 599 is removed reason amount', () => {
    const r = checkBindingClaims('باقة Growth بـ 499 جنيه.', [plan('Growth', '599')], []);
    expect(r.removed.map((x) => x.reason)).toEqual(['amount']);
    expect(r.text).not.toContain('499');
    expect(r.text).toContain('الباقات');
  });
  it('"تقدر ترجّع الفلوس خلال 14 يوم" with no legal source is removed reason policy_term', () => {
    const r = checkBindingClaims('تقدر ترجّع الفلوس خلال 14 يوم.', [], []);
    expect(r.removed.map((x) => x.reason)).toEqual(['policy_term']);
    expect(r.text).not.toContain('14');
  });
  it('the same refund sentence passes when a legal source states 14', () => {
    const src: BindingSource = { kind: 'legal', key: 'refund', text: { ar: 'سياسة الاسترجاع', en: 'Refund policy' }, values: ['14'] };
    expect(checkBindingClaims('تقدر ترجّع الفلوس خلال 14 يوم.', [src], []).removed).toEqual([]);
  });
  it('an unknown plan name is removed reason plan_name', () => {
    const r = checkBindingClaims('جرّب باقة Platinum.', [plan('Growth', '599')], []);
    expect(r.removed.map((x) => x.reason)).toEqual(['plan_name']);
  });
  it('a percent that is in no source is removed, one in a source passes', () => {
    expect(checkBindingClaims('العمولة 5% على كل طلب.', [], []).removed.map((x) => x.reason)).toEqual(['percent']);
    const src: BindingSource = { kind: 'billing', key: 'fee', text: { ar: 'العمولة', en: 'Fee' }, values: ['5'] };
    expect(checkBindingClaims('العمولة ٥٪ على كل طلب.', [src], []).removed).toEqual([]);
  });
  it('a duration claim not in a source is removed reason duration', () => {
    expect(checkBindingClaims('التجديد بياخد 30 days.', [], []).removed.map((x) => x.reason)).toEqual(['duration']);
  });
  it('a product price from a store-data tool result passes', () => {
    const r = checkBindingClaims('سعر العباية 1,500 جنيه.', [], ['{"name":"عباية","price":1500}']);
    expect(r.removed).toEqual([]);
  });
  it('numbers that are counts of the merchant own items (from tool results) pass', () => {
    expect(checkBindingClaims('طلبك هيوصل خلال 3 ايام.', [], ['{"etaDays":3}']).removed).toEqual([]);
  });
  it('only the offending sentence is replaced; the others stay verbatim', () => {
    const r = checkBindingClaims('أهلاً بيك. الباقة بـ 499 جنيه. تحب أساعدك في حاجة تانية؟', [plan('Growth', '599')], []);
    expect(r.removed).toHaveLength(1);
    expect(r.text.startsWith('أهلاً بيك. ')).toBe(true);
    expect(r.text.endsWith('تحب أساعدك في حاجة تانية؟')).toBe(true);
  });
  it('a decimal is not split into two sentences', () => {
    expect(checkBindingClaims('الخصم 10.5 جنيه.', [], ['10.5']).removed).toEqual([]);
  });
  it('an English sentence gets an English pointer', () => {
    const r = checkBindingClaims('The Growth plan costs 499 EGP.', [plan('Growth', '599')], []);
    expect(r.text).toMatch(/See the Plans page/);
  });
  it('a coupon code containing digits is not a numeric claim', () => {
    expect(checkBindingClaims('الكوبون SUMMER10 جاهز.', [], []).removed).toEqual([]);
  });
});

describe('checkBindingClaims: list items', () => {
  const steps = 'خطوات نقل الرقم:\n1. افتح شاشة الأرقام.\n2. الباقة بـ 499 جنيه في الشهر.\n3. اضغط تأكيد.\n4. استنى الموافقة.';
  it('an unsourced numbered step is dropped, not replaced by the pointer, and the rest is renumbered', () => {
    const r = checkBindingClaims(steps, [plan('Growth', '599')], []);
    expect(r.removed.map((x) => x.reason)).toEqual(['amount']);
    expect(r.text).toBe('خطوات نقل الرقم:\n1. افتح شاشة الأرقام.\n2. اضغط تأكيد.\n3. استنى الموافقة.');
    expect(r.text).not.toContain('الباقات');
  });
  it('a bullet is dropped without renumbering anything', () => {
    const r = checkBindingClaims('الحالات:\n- أول حالة.\n- الباقة بـ 499 جنيه.\n- تالت حالة.', [plan('Growth', '599')], []);
    expect(r.text).toBe('الحالات:\n- أول حالة.\n- تالت حالة.');
  });
  it('a sourced step stays and nothing is renumbered', () => {
    const r = checkBindingClaims(steps.replace('499', '599'), [plan('Growth', '599')], []);
    expect(r.removed).toEqual([]);
    expect(r.text).toBe(steps.replace('499', '599'));
  });
  it('a plain sentence (not a list item) is still replaced by the pointer', () => {
    const r = checkBindingClaims('باقة Growth بـ 499 جنيه.', [plan('Growth', '599')], []);
    expect(r.text).toContain('الباقات');
  });
  it('two separate numbered blocks are renumbered independently', () => {
    const r = checkBindingClaims('أ:\n1. واحد.\n2. بـ 499 جنيه.\n3. تلاتة.\n\nب:\n1. اتنين.\n2. اربعة.', [plan('Growth', '599')], []);
    expect(r.text).toBe('أ:\n1. واحد.\n2. تلاتة.\n\nب:\n1. اتنين.\n2. اربعة.');
  });
});

describe('checkBindingClaims: the first step is dropped (live reply, Ebda Chat number move)', () => {
  const reply = 'النقل مفيهوش معالج جاهز، بس الخطوات بسيطة:\n\n1. الباقة بـ 499 جنيه في الشهر.\n2. في Ebda Chat: افتح شاشة الأرقام.\n3. لو Meta قالت الرقم مشغول، استنى.';
  it('the block restarts at 1 when "1." was the dropped step', () => {
    const r = checkBindingClaims(reply, [plan('Growth', '599')], []);
    expect(r.text).toBe('النقل مفيهوش معالج جاهز، بس الخطوات بسيطة:\n\n1. في Ebda Chat: افتح شاشة الأرقام.\n2. لو Meta قالت الرقم مشغول، استنى.');
  });
  it('a block that never had its first step dropped keeps its own start', () => {
    const r = checkBindingClaims('3. اول.\n4. بـ 499 جنيه.\n5. تالت.', [plan('Growth', '599')], []);
    expect(r.text).toBe('3. اول.\n4. تالت.');
  });
});
