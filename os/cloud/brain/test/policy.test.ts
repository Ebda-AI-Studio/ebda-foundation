import { describe, expect, it } from 'vitest';
import { admit, digestMessage, questionMessage } from '../src/telegram';
import { usageGuard, WEEK_MS } from '../src/usage';

describe('telegram admission (hard ceiling: 3 normal + 3 urgent a day, plus one digest)', () => {
  const day = (normal: number, urgent: number, digest = false) => ({ normal, urgent, digest });
  it('dedupes: a key already sent is never sent again', () => {
    expect(admit('question', true, day(0, 0), 3, 3)).toBe('duplicate');
    expect(admit('urgent-outcome', true, day(0, 0), 3, 3)).toBe('duplicate');
  });
  it('questions use the normal bucket and defer beyond it', () => {
    expect(admit('question', false, day(2, 0), 3, 3)).toBe('send');
    expect(admit('question', false, day(3, 0), 3, 3)).toBe('defer');
  });
  it('urgent outcomes and unhealed P1s use their own bucket of 3 and defer beyond it (never unbounded)', () => {
    expect(admit('urgent-outcome', false, day(3, 2), 3, 3)).toBe('send');
    expect(admit('p1-unhealed', false, day(3, 3), 3, 3)).toBe('defer');
    expect(admit('urgent-outcome', false, day(0, 3), 3, 3)).toBe('defer');
  });
  it('the two buckets never exceed 6 non-digest messages in a day', () => {
    let d = day(0, 0);
    let sent = 0;
    const kinds = ['question', 'urgent-outcome', 'p1-unhealed'] as const;
    for (let i = 0; i < 40; i++) {
      const k = kinds[i % 3]!;
      if (admit(k, false, d, 3, 3) === 'send') {
        sent++;
        d = k === 'question' ? day(d.normal + 1, d.urgent) : day(d.normal, d.urgent + 1);
      }
    }
    expect(sent).toBe(6);
  });
  it('one digest a day, outside the buckets', () => {
    expect(admit('digest', false, day(3, 3), 3, 3)).toBe('send');
    expect(admit('digest', false, day(0, 0, true), 3, 3)).toBe('duplicate');
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
    const d = digestMessage({ day: '2026-11-05', outcomes: [{ title: 'bump x', status: 'merged', prUrl: 'https://pr/1' }], raised24h: 4, acted24h: 3, ratio7d: 0.9, pendingQuestions: [], rolledUp: [{ text: 'Ebda OS urgent: could NOT fix\nx down', failed: true }], osBugs: 1, usageNote: null });
    expect(d.dedupeKey).toBe('digest:2026-11-05');
    expect(d.text).toMatch(/merged: bump x https:\/\/pr\/1/);
    expect(d.text).toMatch(/Acted-on: 3\/4 in 24 h; 7-day ratio 90%/);
    expect(d.text).toMatch(/OS bug: 1 finding/);
    expect(d.text).toMatch(/\[delivery failed\] Ebda OS urgent: could NOT fix \/ x down/);
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
