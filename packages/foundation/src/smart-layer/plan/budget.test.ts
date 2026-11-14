import { describe, expect, it } from 'vitest';
import { BUDGET, BudgetExceeded, TurnBudget, checkRate } from './budget';
import type { SmartLayerStorage, TurnCtx } from '../types';

const ctx = (over: Partial<TurnCtx> = {}): TurnCtx => ({ product: 'store', storeId: 's1', userId: 'u1', role: 'owner', locale: 'ar', now: 0, conversationId: 'c1', releaseId: 'r', ...over });
/** Fixed-window counter: just enough of `bump` for the rate rail. */
function fakeStorage(): Pick<SmartLayerStorage, 'bump'> {
  const hits = new Map<string, number[]>();
  return {
    async bump(key, windowMs, now) {
      const arr = (hits.get(key) ?? []).filter((t) => t > now - windowMs);
      arr.push(now);
      hits.set(key, arr);
      return arr.length;
    },
  };
}

describe('TurnBudget', () => {
  it('7th tool call throws BudgetExceeded toolCalls', () => {
    const b = new TurnBudget();
    for (let i = 0; i < BUDGET.toolCalls; i++) b.spendTool();
    expect(() => b.spendTool()).toThrowError(BudgetExceeded);
    try { b.spendTool(); } catch (e) { expect((e as BudgetExceeded).which).toBe('toolCalls'); }
  });
  it('8th model call throws BudgetExceeded modelCalls', () => {
    const b = new TurnBudget();
    for (let i = 0; i < BUDGET.modelCalls; i++) b.spendModel();
    expect(() => b.spendModel()).toThrow(/modelCalls/);
  });
  it('overrides apply per field', () => {
    const b = new TurnBudget({ toolCalls: 1 });
    b.spendTool();
    expect(() => b.spendTool()).toThrow();
  });
  it('the documented v1 numbers', () => {
    expect(BUDGET).toEqual({ toolsOffered: 15, toolCalls: 6, modelCalls: 7, outputTokens: 700, inputChars: 2000, turnsPerConversation: 40, turnsPerUserPerMinute: 10, freeTurnsPerStorePerDay: 150 });
  });
});

describe('checkRate', () => {
  it('10 turns in a minute are ok and the 11th is user_rate', async () => {
    const st = fakeStorage();
    for (let i = 0; i < 10; i++) expect(await checkRate(st, ctx({ now: i * 1000, conversationId: `c${i}` }))).toBe('ok');
    expect(await checkRate(st, ctx({ now: 11_000, conversationId: 'c-x' }))).toBe('user_rate');
  });
  it('turn 41 of one conversation is conversation_full', async () => {
    const st = fakeStorage();
    for (let i = 0; i < 40; i++) expect(await checkRate(st, ctx({ now: i * 7000 }))).toBe('ok');
    expect(await checkRate(st, ctx({ now: 40 * 7000 }))).toBe('conversation_full');
  });
  it('another user has their own minute window', async () => {
    const st = fakeStorage();
    for (let i = 0; i < 11; i++) await checkRate(st, ctx({ now: i, userId: 'a' }));
    expect(await checkRate(st, ctx({ now: 12, userId: 'b' }))).toBe('ok');
  });
});
