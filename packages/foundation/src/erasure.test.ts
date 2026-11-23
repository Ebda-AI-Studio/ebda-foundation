import { describe, expect, it } from 'vitest';
import { erasureOutcome, scrubGaps, unclassifiedTables, unlistedPersonalTables } from './erasure';

describe('erasure completeness (PDPL checklist)', () => {
  const columns = { contacts: ['id', 'wa_id'], notes: ['id', 'body'], billable_sends: ['wamid', 'phone'], orders: ['id', 'buyer_key'], audit: ['id', 'email'] };
  it('lists every table holding phone / buyer_key / email that is neither a target nor exempt with a reason', () => {
    expect(unlistedPersonalTables(columns, ['contacts'], { billable_sends: 'money record, no number kept', audit: '  ' })).toEqual(['audit', 'orders']);
    expect(unlistedPersonalTables(columns, ['contacts', 'orders', 'audit'], { billable_sends: 'money record' })).toEqual([]);
  });
  it('unclassifiedTables fails closed on a table the registry lacks', () => expect(unclassifiedTables(['a', 'b'], { a: {} })).toEqual(['b']));
  it('a scrub must overwrite every matched column', () => {
    expect(scrubGaps({ email: 'customer_email', phone: 'customer_phone' }, { customer_email: '[erased]' })).toEqual(['customer_phone']);
    expect(scrubGaps({ phone: 'p' }, { p: null })).toEqual([]);
  });
  it('job outcome: complete only when every surface ran with nothing remaining', () => {
    const ok = { surface: 'a', erased: 1, remaining: 0 };
    expect(erasureOutcome(['a', 'b'], [ok])).toEqual({ complete: false, missing: ['b'], failed: [] });
    expect(erasureOutcome(['a'], [{ ...ok, remaining: 2 }])).toEqual({ complete: false, missing: [], failed: ['a'] });
    expect(erasureOutcome(['a'], [ok]).complete).toBe(true);
  });
});
