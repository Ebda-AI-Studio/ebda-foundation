import { describe, expect, it } from 'vitest';
import { admit, digestMessage, questionMessage } from '../src/telegram';
import { usageGuard, WEEK_MS } from '../src/usage';

describe('telegram admission', () => {
  it('dedupes: a key already sent is never sent again', () => {
    expect(admit('question', true, 0, false, 3)).toBe('duplicate');
    expect(admit('urgent-outcome', true, 0, false, 3)).toBe('duplicate');
  });
  it('questions share the daily budget and defer beyond it', () => {
    expect(admit('question', false, 2, false, 3)).toBe('send');
    expect(admit('question', false, 3, false, 3)).toBe('defer');
  });
  it('urgent outcomes and unhealed P1s are never deferred (bounded by the urgent cap and dedupe)', () => {
    expect(admit('urgent-outcome', false, 9, false, 3)).toBe('send');
    expect(admit('p1-unhealed', false, 9, false, 3)).toBe('send');
  });
  it('one digest a day, outside the budget', () => {
    expect(admit('digest', false, 3, false, 3)).toBe('send');
    expect(admit('digest', false, 0, true, 3)).toBe('duplicate');
  });
});

describe('message text', () => {
  it('a question carries options, default and deadline; irreversible says nothing happens on silence', () => {
    const m = questionMessage({ id: 'q_1', text: 'Delete old rows?', options: ['proceed', 'hold'], defaultOption: 'hold', deadline: Date.UTC(2026, 10, 6, 12), reversible: false });
    expect(m.text).toMatch(/Options: proceed \/ hold/);
    expect(m.text).toMatch(/nothing happens until you answer/);
    expect(m.buttons?.map((b) => b.data)).toEqual(['q:q_1:proceed', 'q:q_1:hold']);
    const r = questionMessage({ id: 'q_2', text: 'x', options: ['proceed', 'hold'], defaultOption: 'proceed', deadline: Date.UTC(2026, 10, 6, 12), reversible: true });
    expect(r.text).toMatch(/Silence = "proceed" after 2026-11-06 12:00 UTC/);
  });
  it('the digest reports outcomes and the acted-on ratio, not noticings', () => {
    const d = digestMessage({ day: '2026-11-05', outcomes: [{ title: 'bump x', status: 'merged', prUrl: 'https://pr/1' }], raised24h: 4, acted24h: 3, ratio7d: 0.9, pendingQuestions: [], rolledUp: [], osBugs: 1, usageNote: null });
    expect(d.dedupeKey).toBe('digest:2026-11-05');
    expect(d.text).toMatch(/merged: bump x https:\/\/pr\/1/);
    expect(d.text).toMatch(/Acted-on: 3\/4 in 24 h; 7-day ratio 90%/);
    expect(d.text).toMatch(/OS bug: 1 finding/);
  });
});

describe('usage guard', () => {
  const now = Date.UTC(2026, 10, 5);
  it('refuses at or above the threshold', () => {
    expect(usageGuard({ weeklyUsedPct: 80, reportedAt: now - 1000 }, 80, now).allowed).toBe(false);
    expect(usageGuard({ weeklyUsedPct: 95, reportedAt: now - 1000 }, 80, now).allowed).toBe(false);
  });
  it('allows below it', () => {
    expect(usageGuard({ weeklyUsedPct: 79, reportedAt: now - 1000 }, 80, now).allowed).toBe(true);
  });
  it('a report past its reset time no longer blocks', () => {
    expect(usageGuard({ weeklyUsedPct: 99, reportedAt: now - 5000, resetsAt: now - 1 }, 80, now).allowed).toBe(true);
  });
  it('unknown (no report / stale) is allowed but labelled', () => {
    expect(usageGuard(null, 80, now)).toMatchObject({ allowed: true, reason: expect.stringMatching(/usage-unknown/) });
    expect(usageGuard({ weeklyUsedPct: 99, reportedAt: now - WEEK_MS - 1 }, 80, now).reason).toMatch(/usage-unknown/);
  });
});
