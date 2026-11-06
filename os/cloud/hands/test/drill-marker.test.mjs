// withDrillMarker: only a dr-drill job whose outcome note carries the drill's PASS (and no FAIL) is marked drill:'pass'.
import { describe, expect, it } from 'vitest';
import { withDrillMarker } from '../lib/run.mjs';

const drill = { id: 'job_1', finding: { kind: 'dr-drill' } };

describe('withDrillMarker', () => {
  it('PASS note on a successful outcome -> drill:pass', () => {
    expect(withDrillMarker(drill, { status: 'pr_opened', note: 'restore-drill: PASS (api, 41s)' })).toMatchObject({ drill: 'pass' });
    expect(withDrillMarker(drill, { status: 'merged', note: 'PASS' })).toMatchObject({ drill: 'pass' });
  });
  it('FAIL note, FAIL next to PASS, no note, or a failed status -> never pass', () => {
    expect(withDrillMarker(drill, { status: 'merged', note: 'restore-drill: FAIL (row count)' }).drill).toBe('fail');
    expect(withDrillMarker(drill, { status: 'merged', note: 'PASS for api, FAILED for chat' }).drill).toBe('fail');
    expect(withDrillMarker(drill, { status: 'merged' }).drill).toBe('fail');
    expect(withDrillMarker(drill, { status: 'could_not_fix', note: 'PASS' }).drill).toBe('fail');
  });
  it('other job kinds are returned unchanged (no marker)', () => {
    const o = { status: 'merged', note: 'PASS' };
    expect(withDrillMarker({ id: 'j', finding: { kind: 'docs' } }, o)).toBe(o);
    expect(withDrillMarker({ id: 'j' }, o)).toBe(o);
  });
});
