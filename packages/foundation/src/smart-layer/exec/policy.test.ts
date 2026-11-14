import { describe, expect, it } from 'vitest';
import { foldArabic } from '../../text';
import { effectivePolicy } from './policy';
import type { PreviewDraft, SchemaLike, ToolSpec } from '../types';

const any: SchemaLike<unknown> = { safeParse: (x) => ({ success: true, data: x }) };
const tool = (over: Partial<ToolSpec> = {}): ToolSpec => ({ name: 't', capabilityId: 'x.y', description: '', args: any, jsonSchema: {}, policy: 'preview', undo: 'reversible', resultTrust: 'store-data', ...over });
const draft = (over: Partial<PreviewDraft> = {}): PreviewDraft => ({ summary: { ar: '', en: '' }, rows: [], affectedCount: 1, etag: 'e', payload: {}, ...over });

describe('effectivePolicy', () => {
  it('a plain preview tool stays preview with no reasons', () => expect(effectivePolicy(tool(), draft())).toEqual({ policy: 'preview', reasons: [] }));
  it('affectedCount 21 escalates preview to confirm (bulk)', () => expect(effectivePolicy(tool(), draft({ affectedCount: 21 }))).toEqual({ policy: 'confirm', reasons: ['bulk'] }));
  it('affectedCount 20 stays preview', () => expect(effectivePolicy(tool(), draft({ affectedCount: 20 })).policy).toBe('preview'));
  it('the threshold is overridable per call, never below what the caller sets', () => expect(effectivePolicy(tool(), draft({ affectedCount: 6 }), { bulkThreshold: 5 }).policy).toBe('confirm'));
  it('changesPrice escalates even for one item', () => expect(effectivePolicy(tool(), draft({ changesPrice: true }))).toEqual({ policy: 'confirm', reasons: ['price'] }));
  it('touchesCheckout escalates', () => expect(effectivePolicy(tool(), draft({ touchesCheckout: true })).reasons).toEqual(['checkout']));
  it('irreversible undo class is always confirm', () => expect(effectivePolicy(tool({ undo: 'irreversible' }), draft()).reasons).toEqual(['irreversible']));
  it('money, delete and customer messaging are always confirm', () => {
    expect(effectivePolicy(tool({ money: true }), draft()).reasons).toEqual(['money']);
    expect(effectivePolicy(tool({ deletes: true }), draft()).reasons).toEqual(['delete']);
    expect(effectivePolicy(tool({ messagesCustomers: true }), draft()).reasons).toEqual(['customer_message']);
  });
  it('a tool declared confirm is confirm', () => expect(effectivePolicy(tool({ policy: 'confirm' }), draft())).toEqual({ policy: 'confirm', reasons: ['declared'] }));
  it('reasons accumulate', () => expect(effectivePolicy(tool({ money: true }), draft({ affectedCount: 50, changesPrice: true })).reasons).toEqual(['money', 'bulk', 'price']));
  it('a free tool can never reach effectivePolicy', () => expect(() => effectivePolicy(tool({ policy: 'free' }), draft())).toThrow(/free/));
  it('a bad affectedCount (NaN, negative, fractional) fails toward confirm', () => {
    for (const n of [Number.NaN, -1, 1.5, Infinity]) expect(effectivePolicy(tool(), draft({ affectedCount: n })).policy, String(n)).toBe('confirm');
  });
  it('counts Arabic-Indic digits toward the bulk trigger: the adapter parses, the engine trusts only draft.affectedCount', () => {
    const parse = (text: string) => Number(/\d+/.exec(foldArabic(text))![0]);
    expect(parse('خصم على ٢٥ منتج')).toBe(25);
    expect(effectivePolicy(tool(), draft({ affectedCount: parse('خصم على ٢٥ منتج') })).reasons).toEqual(['bulk']);
    // model text that SAYS 25 changes nothing when the preview counted 1
    expect(effectivePolicy(tool({ description: 'خصم على ٢٥ منتج' }), draft({ affectedCount: 1, rows: [{ label: { ar: '٢٥ منتج', en: '25 products' } }] })).policy).toBe('preview');
  });
});
