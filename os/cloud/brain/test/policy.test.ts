import { describe, expect, it } from 'vitest';
import { admit, DIGEST_MAX_CHARS, DIGEST_MAX_LINES, digestMessage, questionMessage } from '../src/telegram';
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
  it('the digest is short: counts, top 5 that need Ahmad, one not-set-up line, social block, a link', () => {
    const needs = Array.from({ length: 14 }, (_, i) => `PR Ebda-AI-Studio/ebda-store#${i} has failing checks: ${'long title '.repeat(20)}`);
    const d = digestMessage({
      day: '2026-11-11', fixed: 3, open: 21, resolved: 14, halted: 'HANDS_HALT is set on the Worker', needs,
      notSetUp: ['services', 'deploy-drift', 'sentry-stale'], social: 'Social (48 h): 2 published\nModes: Ebda approval\nSocial issues: none\nEXTRA LINE', dashUrl: 'https://os.ebda.app/dash/',
    });
    const lines = d.text.split('\n');
    expect(d.dedupeKey).toBe('digest:2026-11-11');
    expect(lines.length).toBeLessThanOrEqual(DIGEST_MAX_LINES);
    expect(d.text.length).toBeLessThanOrEqual(DIGEST_MAX_CHARS);
    expect(lines[0]).toContain('HANDS HALTED');
    expect(lines[1]).toBe('Fixed 3 | Open 21 | Needs you 14 | Resolved 14');
    expect(lines.filter((l) => l.startsWith('! '))).toHaveLength(5);
    expect(d.text).toContain('Not set up: services, deploy-drift, sentry-stale');
    expect(d.text).not.toContain('EXTRA LINE');
    expect(lines.at(-1)).toBe('Full list (+9 more): https://os.ebda.app/dash/');
    expect(d.text).not.toMatch(/Done:|no longer reported|configured:/);
  });
  it('an empty day is still one tiny message', () => {
    const d = digestMessage({ day: '2026-11-11', fixed: 0, open: 0, resolved: 0, needs: [], notSetUp: [], dashUrl: 'https://os.ebda.app/dash/' });
    expect(d.text.split('\n')).toHaveLength(3);
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
