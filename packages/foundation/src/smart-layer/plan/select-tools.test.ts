import { describe, expect, it } from 'vitest';
import { selectTools } from './select-tools';
import type { RegistryCap, RegistryView, SchemaLike, ToolSpec } from '../types';

const any: SchemaLike<unknown> = { safeParse: (x) => ({ success: true, data: x }) };
const cap = (id: string, titleAr: string, titleEn: string, examples: string[], over: Partial<RegistryCap> = {}): RegistryCap => ({ id, version: 1, status: 'live', policy: 'preview', undo: 'reversible', title: { ar: titleAr, en: titleEn }, appPaths: [], uiLabels: { ar: [titleAr], en: [titleEn] }, helpArticle: null, examples, area: 'x', ...over });
const tool = (name: string, capabilityId: string, description: string, policy: ToolSpec['policy'] = 'preview'): ToolSpec => ({ name, capabilityId, description, args: any, jsonSchema: { type: 'object' }, policy, undo: 'reversible', resultTrust: 'store-data' });
const view = (caps: RegistryCap[]): RegistryView => ({ caps: new Map(caps.map((c) => [c.id, c])), byAppPath: () => undefined });

const base = [
  cap('marketing.coupons', 'الكوبونات والخصومات', 'Coupons', ['ازاي اعمل خصم على المنتجات', 'how do I add a discount coupon']),
  cap('catalog.bulk-price', 'تعديل الأسعار بالجملة', 'Bulk price edit', ['عايز اغير سعر كل المنتجات']),
  cap('orders.list', 'الطلبات', 'Orders', ['فين طلباتي', 'where are my orders'], { policy: 'free' }),
  cap('assistant.help', 'مساعدة', 'Help', [], { policy: 'free' }),
  cap('assistant.where', 'وريني فين', 'Show me where', [], { policy: 'free' }),
];
const tools = [
  tool('create_coupon', 'marketing.coupons', 'Create a discount coupon for products'),
  tool('bulk_price', 'catalog.bulk-price', 'Change prices of many products'),
  tool('list_orders', 'orders.list', 'List recent orders', 'free'),
  tool('help_search', 'assistant.help', 'Search help articles', 'free'),
  tool('show_me_where', 'assistant.where', 'Link to a screen', 'free'),
];
const o = { mode: 'act' as const, untrustedInContext: false };

describe('selectTools', () => {
  it('"عايز أعمل خصم ١٠٪ على العبايات" ranks create_coupon first among scored tools', () => {
    const out = selectTools('عايز أعمل خصم ١٠٪ على العبايات', tools, view(base), o).map((t) => t.name);
    expect(out.filter((n) => !['help_search', 'show_me_where'].includes(n))[0]).toBe('create_coupon');
  });
  it('franco query ranks the same way', () => {
    const out = selectTools('3ayez a3ml coupon discount', tools, view(base), o).map((t) => t.name);
    expect(out.filter((n) => !['help_search', 'show_me_where'].includes(n))[0]).toBe('create_coupon');
  });
  it('always tools are offered even with no lexical match', () => {
    const out = selectTools('zzz qqq', tools, view(base), o).map((t) => t.name);
    expect(out).toContain('help_search');
    expect(out).toContain('show_me_where');
  });
  it('never returns more than 15 with 60 candidates', () => {
    const caps = Array.from({ length: 60 }, (_, i) => cap(`a.c${i}`, `منتج ${i}`, `Product ${i}`, ['خصم منتج']));
    const many = caps.map((c, i) => tool(`t${i}`, c.id, 'product discount'));
    expect(selectTools('خصم منتج', many, view(caps), o).length).toBeLessThanOrEqual(15);
    expect(selectTools('خصم منتج', many, view(caps), { ...o, max: 99 }).length).toBeLessThanOrEqual(15);
  });
  it('planned and in-pr capability tools are never offered', () => {
    const reg = view([...base, cap('x.planned', 'خصم', 'Discount', ['خصم'], { status: 'planned' })]);
    const out = selectTools('خصم', [...tools, tool('planned_tool', 'x.planned', 'discount')], reg, o).map((t) => t.name);
    expect(out).not.toContain('planned_tool');
  });
  it('a forbidden capability tool is never offered', () => {
    const reg = view([...base, cap('x.forb', 'خصم', 'Discount', ['خصم'], { policy: 'forbidden' })]);
    expect(selectTools('خصم', [...tools, tool('forb_tool', 'x.forb', 'discount')], reg, o).map((t) => t.name)).not.toContain('forb_tool');
  });
  it('a tool whose capability is not in the registry is never offered', () => {
    expect(selectTools('خصم', [tool('ghost', 'nope.cap', 'discount')], view(base), o)).toEqual([]);
  });
  it('a killed tool is not offered', () => {
    const out = selectTools('خصم', tools, view(base), { ...o, killed: new Set(['create_coupon']) }).map((t) => t.name);
    expect(out).not.toContain('create_coupon');
  });
  it('answer-only mode offers only free tools', () => {
    const out = selectTools('خصم طلبات', tools, view(base), { ...o, mode: 'answer-only' });
    expect(out.length).toBeGreaterThan(0);
    for (const t of out) expect(t.policy).toBe('free');
  });
  it('mode off offers nothing', () => {
    expect(selectTools('خصم', tools, view(base), { ...o, mode: 'off' })).toEqual([]);
  });
  it('untrusted content keeps free + always', () => {
    const out = selectTools('خصم طلبات', tools, view(base), { ...o, untrustedInContext: true });
    for (const t of out) expect(t.policy).toBe('free');
    expect(out.map((t) => t.name)).toContain('help_search');
  });
  it('vector scores lift a tool the lexicon missed', () => {
    const out = selectTools('qqq', tools, view(base), { ...o, vectorScores: new Map([['bulk_price', 0.9]]) }).map((t) => t.name);
    expect(out[0]).toBe('bulk_price');
  });
});
