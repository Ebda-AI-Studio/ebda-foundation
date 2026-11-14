import { describe, expect, it } from 'vitest';
import { autoConfirmKey, firstPaymentCapMinor, isCleanPayment, nextAutoState, REVERT_GRACE_MS, revertGraceUntil, revertKey, unusedCreditsToRemove, type AutoEvent, type AutoState } from './instapay-state';

const STATES: AutoState[] = ['pending_decision', 'auto_confirmed', 'needs_human', 'reverted', 'failed'];
const EVENTS: AutoEvent[] = ['decide_auto', 'decide_human', 'revert', 'activation_failed'];
const LEGAL: Record<string, string> = {
  'pending_decision:decide_auto': 'auto_confirmed',
  'pending_decision:decide_human': 'needs_human',
  'pending_decision:activation_failed': 'failed',
  'auto_confirmed:revert': 'reverted',
  'reverted:revert': 'reverted',
};

describe('nextAutoState: every state x event', () => {
  for (const s of STATES) for (const e of EVENTS) it(`${s} + ${e}`, () => expect(nextAutoState(s, e)).toBe(LEGAL[`${s}:${e}`] ?? 'illegal'));
  it('revert replay is a no-op, revert on a never-confirmed payment is illegal', () => {
    expect(nextAutoState('reverted', 'revert')).toBe('reverted');
    for (const s of ['pending_decision', 'needs_human', 'failed'] as const) expect(nextAutoState(s, 'revert')).toBe('illegal');
  });
  it('a revert followed by any other event is illegal', () => {
    for (const e of ['decide_auto', 'decide_human', 'activation_failed'] as const) expect(nextAutoState('reverted', e)).toBe('illegal');
  });
  it('unknown state or event is illegal', () => {
    expect(nextAutoState('nope' as any, 'revert')).toBe('illegal');
    expect(nextAutoState('auto_confirmed', 'nope' as any)).toBe('illegal');
  });
});

describe('keys, grace, cap', () => {
  it('key formats', () => {
    expect(autoConfirmKey('store', 'abc')).toBe('instapay-auto:store:abc');
    expect(revertKey('chat', '9')).toBe('instapay-revert:chat:9');
  });
  it('grace is 48 h', () => {
    expect(REVERT_GRACE_MS).toBe(172_800_000);
    expect(revertGraceUntil(0)).toBe(172_800_000);
    expect(revertGraceUntil(5)).toBe(172_800_005);
  });
  it('cap is one month of the plan; no plan or bad price -> 0', () => {
    expect(firstPaymentCapMinor({ monthlyPriceMinor: 120000 })).toBe(120000);
    for (const v of [null, 0, -1, 1.5, NaN, Infinity]) expect(firstPaymentCapMinor({ monthlyPriceMinor: v as any })).toBe(0);
  });
});

describe('isCleanPayment (INSTAPAY-CLEAN-1: clean once it appeared in a SENT digest and was not reverted)', () => {
  const T = 1_000_000;
  const auto = (digestSentAt: number | null, revertedAt: number | null = null) => ({ confirmedBy: 'auto' as const, confirmedAt: T, digestSentAt, revertedAt });
  it('human is clean at once unless reverted', () => {
    expect(isCleanPayment({ confirmedBy: 'human', confirmedAt: T, digestSentAt: null, revertedAt: null }, T)).toBe(true);
    expect(isCleanPayment({ confirmedBy: 'human', confirmedAt: T, digestSentAt: null, revertedAt: T + 1 }, T + 1e9)).toBe(false);
  });
  it('an auto payment never in a digest is NEVER clean, however old (the second payment waits for the digest)', () => {
    expect(isCleanPayment(auto(null), T)).toBe(false);
    expect(isCleanPayment(auto(null), T + 1e12)).toBe(false);
  });
  it('clean the moment the digest was sent: no extra waiting window', () => {
    const D = T + 3600_000;
    expect(isCleanPayment(auto(D), D)).toBe(true);
    expect(isCleanPayment(auto(D), D + 1)).toBe(true);
    expect(isCleanPayment(auto(D), D - 1)).toBe(false); // evaluated before the digest was sent
  });
  it('a digest stamped BEFORE the confirmation cannot have contained the payment: not clean', () => {
    expect(isCleanPayment(auto(T - 1), T + 1e9)).toBe(false);
    expect(isCleanPayment(auto(T), T)).toBe(true);
  });
  it('a revert makes it permanently not clean, whether or not a digest was sent', () => {
    expect(isCleanPayment(auto(T + 10, T + 20), T + 1e9)).toBe(false);
    expect(isCleanPayment(auto(null, T + 20), T + 1e9)).toBe(false);
  });
  it('the review scenario: confirmed just after the day digest, 24 h later it is still NOT clean until the NEXT digest goes out', () => {
    const day1Digest = T - 1000; // sent before the payment: cannot list it
    expect(isCleanPayment(auto(day1Digest), T + 24 * 3600_000)).toBe(false);
    const day2Digest = T + 23 * 3600_000;
    expect(isCleanPayment(auto(day2Digest), day2Digest)).toBe(true);
  });
  it('garbage never counts as clean', () => {
    for (const d of [NaN, Infinity, '5' as any, undefined as any]) expect(isCleanPayment(auto(d), T + 1e9), String(d)).toBe(false);
    expect(isCleanPayment({ confirmedBy: 'x' as any, confirmedAt: T, digestSentAt: T, revertedAt: null }, T + 1e9)).toBe(false);
    expect(isCleanPayment({ ...auto(T), revertedAt: undefined as any }, T + 1e9)).toBe(false);
    expect(isCleanPayment(auto(T), NaN)).toBe(false);
  });
});

describe('unusedCreditsToRemove (revert never claws back consumed credits, never goes negative)', () => {
  it.each([
    [{ granted: 100, consumed: 0, balance: 100 }, 100],
    [{ granted: 100, consumed: 30, balance: 70 }, 70],
    [{ granted: 100, consumed: 100, balance: 0 }, 0],
    [{ granted: 100, consumed: 30, balance: 40 }, 40], // balance lower than the unused remainder: never below zero
    [{ granted: 100, consumed: 0, balance: 500 }, 100], // other credits in the balance are not touched
    [{ granted: 100, consumed: 150, balance: 20 }, 0],
    [{ granted: -1, consumed: 0, balance: 5 }, 0],
    [{ granted: 1.5, consumed: 0, balance: 5 }, 0],
    [{ granted: 100, consumed: NaN, balance: 5 }, 0],
  ])('%j -> %i', (c, n) => expect(unusedCreditsToRemove(c)).toBe(n));
  it('property: result is within [0, balance] and within [0, granted - consumed]', () => {
    let s = 7;
    const r = () => ((s = (s * 1664525 + 1013904223) >>> 0) % 1000);
    for (let i = 0; i < 5000; i++) {
      const c = { granted: r(), consumed: r(), balance: r() };
      const x = unusedCreditsToRemove(c);
      expect(x).toBeGreaterThanOrEqual(0);
      expect(x).toBeLessThanOrEqual(c.balance);
      expect(x).toBeLessThanOrEqual(Math.max(0, c.granted - c.consumed));
    }
  });
});
