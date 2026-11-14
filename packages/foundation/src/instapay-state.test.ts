import { describe, expect, it } from 'vitest';
import { autoConfirmKey, CLEAN_AFTER_MS, firstPaymentCapMinor, isCleanPayment, nextAutoState, REVERT_GRACE_MS, revertGraceUntil, revertKey, unusedCreditsToRemove, type AutoEvent, type AutoState } from './instapay-state';

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

describe('isCleanPayment', () => {
  const T = 1_000_000;
  it('human is clean at once', () => expect(isCleanPayment({ confirmedBy: 'human', confirmedAt: T, revertedAt: null }, T)).toBe(true));
  it('auto is not clean until 24 h: boundaries', () => {
    expect(CLEAN_AFTER_MS).toBe(86_400_000);
    expect(isCleanPayment({ confirmedBy: 'auto', confirmedAt: T, revertedAt: null }, T + CLEAN_AFTER_MS - 1)).toBe(false);
    expect(isCleanPayment({ confirmedBy: 'auto', confirmedAt: T, revertedAt: null }, T + CLEAN_AFTER_MS)).toBe(true);
  });
  it('a reverted payment is never clean, even a human one, even after 24 h', () => {
    expect(isCleanPayment({ confirmedBy: 'human', confirmedAt: T, revertedAt: T + 1 }, T + 10 * CLEAN_AFTER_MS)).toBe(false);
    expect(isCleanPayment({ confirmedBy: 'auto', confirmedAt: T, revertedAt: T + 1 }, T + 10 * CLEAN_AFTER_MS)).toBe(false);
  });
  it('unknown confirmer is not clean', () => expect(isCleanPayment({ confirmedBy: 'x' as any, confirmedAt: T, revertedAt: null }, T + 10 * CLEAN_AFTER_MS)).toBe(false));
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
