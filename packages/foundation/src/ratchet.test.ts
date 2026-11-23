import { describe, expect, it } from 'vitest';
import { applyBaseline, baselineGrowth, guardOutcome, violationId } from './ratchet';

const v = (rule: string, key: string) => ({ rule, key, message: 'm' });

describe('ratchet', () => {
  it('violationId joins rule and key', () => expect(violationId(v('r', 'k'))).toBe('r|k'));
  it('a baselined violation is tolerated and warns, not fails', () => {
    const o = guardOutcome(applyBaseline([v('r', 'k')], ['r|k']));
    expect(o.failures).toEqual([]);
    expect(o.warnings).toHaveLength(1);
    expect(o.warnings[0]).toMatch(/^::warning::/);
  });
  it('a violation not in the baseline is fresh and fails', () => {
    const r = applyBaseline([v('r', 'new')], ['r|old']);
    expect(r.fresh).toHaveLength(1);
    expect(guardOutcome(r).failures.some((f) => f.includes('r|new'))).toBe(true);
  });
  it('a baseline id with no violation is stale and fails (the baseline must shrink in the same PR)', () => {
    const r = applyBaseline([], ['r|fixed']);
    expect(r.stale).toEqual(['r|fixed']);
    expect(guardOutcome(r).failures.some((f) => f.includes('r|fixed'))).toBe(true);
  });
  it('baselineGrowth returns ids the base lacks, in order', () => {
    expect(baselineGrowth(['a', 'b'], ['a'])).toEqual(['b']);
    expect(baselineGrowth(['a'], ['a', 'b'])).toEqual([]);
  });
  it('an empty result has no failures or warnings', () => expect(guardOutcome(applyBaseline([], []))).toEqual({ failures: [], warnings: [] }));
});
