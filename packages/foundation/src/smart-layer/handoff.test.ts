import { describe, expect, it } from 'vitest';
import { handoffReason, summariseUnanswered } from './handoff';
import type { AuditRow } from './types';

const st = (over = {}) => ({ notCoveredStreak: 0, failedTools: 0, text: 'ازاي اضيف منتج', forbiddenHit: false, ...over });

describe('handoffReason', () => {
  it('"عايز أكلم حد من الدعم" → asked_human', () => expect(handoffReason(st({ text: 'عايز أكلم حد من الدعم' }))).toBe('asked_human'));
  it('franco and english asks', () => {
    expect(handoffReason(st({ text: '3ayez akalem 7ad men el support' }))).toBe('asked_human');
    expect(handoffReason(st({ text: 'let me talk to a human please' }))).toBe('asked_human');
  });
  it('two not-covered turns → low_confidence, one is not', () => {
    expect(handoffReason(st({ notCoveredStreak: 2 }))).toBe('low_confidence');
    expect(handoffReason(st({ notCoveredStreak: 1 }))).toBeNull();
  });
  it('two failed tools → repeated_failure', () => expect(handoffReason(st({ failedTools: 2 }))).toBe('repeated_failure'));
  it('frustration lexicon', () => {
    expect(handoffReason(st({ text: 'زهقت منك انت مش بتفهم حاجة' }))).toBe('frustration');
    expect(handoffReason(st({ text: 'this is useless' }))).toBe('frustration');
  });
  it('a forbidden request hands off', () => expect(handoffReason(st({ forbiddenHit: true }))).toBe('forbidden'));
  it('a normal question returns null', () => expect(handoffReason(st())).toBeNull());
  it('asked_human beats the rest', () => expect(handoffReason(st({ text: 'support', notCoveredStreak: 3, failedTools: 3 }))).toBe('asked_human'));
});

describe('summariseUnanswered', () => {
  const row = (q: string, outcome: AuditRow['outcome']): AuditRow => ({ id: q + Math.random(), storeId: 's', userId: 'u', turnId: 't', at: 0, releaseId: 'r', maskedPrompt: q, maskedOutput: '', rails: {}, toolsOffered: [], toolCalls: [], outcome, inputTokens: 0, outputTokens: 0, model: 'm' });
  it('groups not_covered prompts case/diacritic-insensitively, most frequent first', () => {
    const out = summariseUnanswered([row('ازاي أربط الدومين', 'not_covered'), row('ازاي اربط الدومين', 'not_covered'), row('Other', 'not_covered'), row('answered', 'answered')]);
    expect(out[0]).toEqual({ question: 'ازاي أربط الدومين', count: 2 });
    expect(out).toHaveLength(2);
  });
});
