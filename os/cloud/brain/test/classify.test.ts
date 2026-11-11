import { describe, expect, it } from 'vitest';
import { classifyFinding } from '../src/classify';
import type { Finding } from '../src/findings';

const f = (x: Partial<Finding>): Finding => ({ source: 'test', kind: 'x', key: 'k', title: 't', ...x });

describe('classifyFinding: urgent class (1) outage / money path', () => {
  it('prod outage after self-heal exhausted -> urgent', () => {
    expect(classifyFinding(f({ kind: 'prod-outage', selfHealExhausted: true })).lane).toBe('urgent');
  });
  it('broken payment webhook after self-heal exhausted -> urgent (money path beats the money=question rule)', () => {
    expect(classifyFinding(f({ kind: 'money-path-broken', touches: ['money', 'payment-webhook'], selfHealExhausted: true })).lane).toBe('urgent');
  });
  it('near miss: outage still inside the self-heal retry budget -> nightly', () => {
    const c = classifyFinding(f({ kind: 'prod-outage', selfHealExhausted: false }));
    expect(c.lane).toBe('nightly');
    expect(c.reason).toMatch(/retry budget/);
  });
  it('near miss: a slow page is not an outage -> nightly', () => {
    expect(classifyFinding(f({ kind: 'perf-regression', severity: 'P2' })).lane).toBe('nightly');
  });
});

describe('classifyFinding: urgent class (2) critical / KEV in deployed code', () => {
  it('CVSS 9.8 runtime dependency -> urgent', () => {
    expect(classifyFinding(f({ kind: 'dependency-advisory', cvss: 9.8, depScope: 'runtime', deployed: true })).lane).toBe('urgent');
  });
  it('CVSS exactly 9.0 runtime -> urgent (boundary)', () => {
    expect(classifyFinding(f({ kind: 'dependency-advisory', cvss: 9.0, depScope: 'runtime', deployed: true })).lane).toBe('urgent');
  });
  it('KEV-listed CVSS 6.5 runtime -> urgent', () => {
    const c = classifyFinding(f({ kind: 'dependency-advisory', cvss: 6.5, kev: true, depScope: 'runtime', deployed: true }));
    expect(c.lane).toBe('urgent');
    expect(c.reason).toMatch(/KEV/);
  });
  it('unknown scope in a deployed repo -> urgent', () => {
    expect(classifyFinding(f({ kind: 'dependency-advisory', cvss: 9.1, depScope: 'unknown', deployed: true })).lane).toBe('urgent');
  });
  it('near miss: deployed unknown (unset) is NOT deployed -> nightly', () => {
    expect(classifyFinding(f({ kind: 'dependency-advisory', cvss: 9.8, kev: true, depScope: 'runtime' })).lane).toBe('nightly');
  });
  it('near miss: KEV-listed dev-only dependency in a deployed repo -> nightly', () => {
    expect(classifyFinding(f({ kind: 'dependency-advisory', cvss: 9.8, kev: true, depScope: 'development', deployed: true })).lane).toBe('nightly');
  });
  it('near miss: CVSS 8.8 dev-only dependency -> nightly, auto-merge allowed (plain bump)', () => {
    const c = classifyFinding(f({ kind: 'dependency-advisory', cvss: 8.8, depScope: 'development' }));
    expect(c).toMatchObject({ lane: 'nightly', mergePolicy: 'auto-when-gate-green' });
  });
  it('near miss: CVSS 9.8 dev-only -> nightly (not deployed)', () => {
    expect(classifyFinding(f({ kind: 'dependency-advisory', cvss: 9.8, depScope: 'development' })).lane).toBe('nightly');
  });
  it('near miss: CVSS 8.9 runtime, not KEV -> nightly', () => {
    expect(classifyFinding(f({ kind: 'dependency-advisory', cvss: 8.9, depScope: 'runtime', deployed: true })).lane).toBe('nightly');
  });
  it('near miss: KEV-listed but in a repo that is not deployed -> nightly', () => {
    expect(classifyFinding(f({ kind: 'dependency-advisory', cvss: 9.8, kev: true, depScope: 'runtime', deployed: false })).lane).toBe('nightly');
  });
  it('a non-urgent advisory whose fix touches auth needs a question at PR time', () => {
    expect(classifyFinding(f({ kind: 'dependency-advisory', cvss: 7, depScope: 'runtime', touches: ['auth'] })).mergePolicy).toBe('pr-and-question');
  });
});

describe('classifyFinding: urgent class (3) data exposure', () => {
  it('PII leak -> urgent', () => {
    expect(classifyFinding(f({ kind: 'pii-leak' })).lane).toBe('urgent');
  });
  it('secret leak -> urgent, never auto-merged', () => {
    expect(classifyFinding(f({ kind: 'secret-leak' }))).toMatchObject({ lane: 'urgent', mergePolicy: 'pr-and-question' });
  });
  it('near miss: a gitleaks rule change (no exposure) is not urgent', () => {
    expect(classifyFinding(f({ kind: 'lint', title: 'gitleaks config drift' })).lane).toBe('nightly');
  });
});

describe('classifyFinding: question lane (destructive / sensitive)', () => {
  for (const touches of [['data-deletion'], ['prod-data'], ['purchase'], ['secrets'], ['billing']]) {
    it(`touches ${touches[0]} -> question with destructive reason`, () => {
      const c = classifyFinding(f({ kind: 'refactor', touches }));
      expect(c.lane).toBe('question');
      expect(c.reason).toMatch(/destructive/);
    });
  }
  for (const kind of ['security-rls', 'payout-migration', 'auth-session', 'deploy-config', 'checkout-copy']) {
    it(`compound kind ${kind} -> question (substring match, fail-safe)`, () => {
      expect(classifyFinding(f({ kind })).lane).toBe('question');
    });
  }
});

describe('classifyFinding: nightly lane', () => {
  for (const kind of ['docs', 'test', 'flaky-test', 'dep-bump', 'lockfile-drift']) {
    it(`pre-approved ${kind} -> nightly, auto-merge when gate green`, () => {
      expect(classifyFinding(f({ kind }))).toMatchObject({ lane: 'nightly', mergePolicy: 'auto-when-gate-green' });
    });
  }
  it('ordinary code change -> nightly, PR plus one question', () => {
    expect(classifyFinding(f({ kind: 'ci-failure' }))).toMatchObject({ lane: 'nightly', mergePolicy: 'pr-and-question' });
  });
  it('dream backlog item -> nightly', () => {
    expect(classifyFinding(f({ source: 'dream', kind: 'product-improvement' })).lane).toBe('nightly');
  });
});

describe('classifyFinding: dreaming-cycle kinds become jobs (never dropped, never urgent)', () => {
  const kinds = ['improvement', 'reflect-unenforced-lesson', 'perf', 'seo', 'a11y', 'live-unreachable', 'failing-gate', 'self-heal-broken', 'app-error'];
  it.each(kinds)('%s -> nightly, PR plus one question', (kind) => {
    const c = classifyFinding(f({ source: 'dream', kind, severity: 'P3', detail: { product: 'ebda-store', evidence: 'https://example.test took 2.1s' } }));
    expect(c.lane).toBe('nightly');
    expect(c.mergePolicy).toBe('pr-and-question');
  });
  it('dream scan dependency / lockfile / test kinds are the pre-approved nightly classes', () => {
    expect(classifyFinding(f({ source: 'dream', kind: 'lockfile-drift' }))).toMatchObject({ lane: 'nightly', mergePolicy: 'auto-when-gate-green' });
    expect(classifyFinding(f({ source: 'dream', kind: 'test' }))).toMatchObject({ lane: 'nightly', mergePolicy: 'auto-when-gate-green' });
    expect(classifyFinding(f({ source: 'dream', kind: 'dependency-advisory', severity: 'P2' }))).toMatchObject({ lane: 'nightly', mergePolicy: 'auto-when-gate-green' });
  });
});

describe('M-1: lint / format are not pre-approved (their proof was forgeable)', () => {
  it.each(['lint', 'lint-autofix', 'format'])('%s -> nightly, PR plus one question', (kind) => {
    expect(classifyFinding(f({ kind }))).toMatchObject({ lane: 'nightly', mergePolicy: 'pr-and-question' });
  });
});

describe('I-2: dream config self-reports are digest-only (a config gap never spends a container)', () => {
  it.each(['scan-target-missing', 'dream-scan-failed'])('%s -> digest', (kind) => {
    expect(classifyFinding(f({ source: 'dream', kind, severity: 'P3' })).lane).toBe('digest');
  });
});

describe('classifyFinding: monitor self-reports are digest-only from ANY source (R-4a-1, R-4a-2)', () => {
  it.each(['dream', 'watcher', 'heal-watch', 'self-heal'])('monitor-unconfigured and watcher-error from %s -> digest, never a job or a question', (source) => {
    for (const kind of ['monitor-unconfigured', 'watcher-error']) {
      const c = classifyFinding(f({ source, kind, severity: 'P1', selfHealExhausted: true, touches: ['money'] }));
      expect(c.lane).toBe('digest');
      expect(['nightly', 'urgent', 'question']).not.toContain(c.lane);
    }
  });
});

describe('classifyFinding: prod-watch production state (AI OS primary operator)', () => {
  it('a prod-watch outage with no repo is recorded as digest: no hands job, no second message (must fire)', () => {
    const c = classifyFinding(f({ source: 'prod-watch', kind: 'prod-outage', key: 'probe:api', selfHealExhausted: true }));
    expect(c.lane).toBe('digest');
    expect(c.alert).toBeUndefined();
  });
  it('the same outage from another source keeps the outage rules (must not fire)', () => {
    expect(classifyFinding(f({ source: 'health', kind: 'prod-outage', selfHealExhausted: true })).lane).toBe('urgent');
    expect(classifyFinding(f({ source: 'prod-watch', kind: 'prod-outage', repo: 'o/r', selfHealExhausted: true })).lane).toBe('urgent');
  });
});

describe('classifyFinding: drain loop findings (ops/drain.sh)', () => {
  it('drain-stall is one P1 alert in the digest lane and never a hands job', () => {
    const c = classifyFinding(f({ source: 'drain-ebda-store', kind: 'drain-stall', repo: 'o/r', severity: 'P1' }));
    expect(c.lane).toBe('digest');
    expect(c.alert).toBe(true);
  });
  it.each(['loop-main-red', 'loop-merge-stall'])('%s is one P1 alert in the digest lane and never a hands job (LOOP-WATCH-1)', (kind) => {
    const c = classifyFinding(f({ source: 'watcher', kind, repo: 'o/r', severity: 'P1' }));
    expect(c.lane).toBe('digest');
    expect(c.alert).toBe(true);
  });
  it('drain-held (risky PR waiting for the AI review) is digest only, no alert', () => {
    const c = classifyFinding(f({ source: 'drain-ebda-store', kind: 'drain-held', repo: 'o/r', severity: 'P2' }));
    expect(c.lane).toBe('digest');
    expect(c.alert).toBeUndefined();
  });
});

