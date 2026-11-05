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
  for (const kind of ['docs', 'test', 'lint', 'flaky-test', 'dep-bump', 'lockfile-drift', 'format']) {
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
