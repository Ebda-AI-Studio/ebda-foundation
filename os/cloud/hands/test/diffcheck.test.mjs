// The diff-bound merge rule, unit level.
import { describe, expect, it } from 'vitest';
import { parseThreshold } from '../lib/config.mjs';
import { diffAllowsAutoMerge, globToRegExp, packageJsonDepsOnly, protectedFor, scanSecrets } from '../lib/diffcheck.mjs';
import { decide, UsageGuard } from '../lib/usage-guard.mjs';

const w = (path, buf = 'x', base = null) => ({ path, type: 'write', buf: Buffer.from(buf), base: base === null ? null : Buffer.from(base) });

describe('diffAllowsAutoMerge', () => {
  it('docs: markdown and docs/** only', () => {
    expect(diffAllowsAutoMerge('docs', [w('README.md'), w('docs/guide/setup.md')]).ok).toBe(true);
    expect(diffAllowsAutoMerge('docs', [w('src/payments/charge.ts')]).ok).toBe(false);
    expect(diffAllowsAutoMerge('docs', [w('docs/payments.md')]).reason).toMatch(/sensitive/);
  });
  it('dependency bumps: manifests + lockfiles; package.json only when deps alone changed', () => {
    const base = '{"scripts":{"test":"vitest"},"dependencies":{"a":"1"}}';
    expect(diffAllowsAutoMerge('cve-bump', [w('package.json', '{"scripts":{"test":"vitest"},"dependencies":{"a":"2"}}', base), w('package-lock.json')]).ok).toBe(true);
    expect(diffAllowsAutoMerge('cve-bump', [w('package.json', '{"scripts":{"test":"true"},"dependencies":{"a":"2"}}', base)]).ok).toBe(false);
    expect(diffAllowsAutoMerge('dep-bump', [w('src/index.ts')]).ok).toBe(false);
    expect(diffAllowsAutoMerge('dep-bump', [w('.npmrc')]).ok).toBe(false);
  });
  it('tests: test files only, never test config', () => {
    expect(diffAllowsAutoMerge('test', [w('src/__tests__/a.test.ts'), w('tests/e.py')]).ok).toBe(true);
    expect(diffAllowsAutoMerge('test', [w('jest.config.js')]).ok).toBe(false);
    expect(diffAllowsAutoMerge('flaky-test', [w('test/auth.test.ts')]).ok).toBe(false); // sensitive name
  });
  it('lint passes the path check but protected / sensitive / test-defining paths still fail; deletions fail outside docs', () => {
    expect(diffAllowsAutoMerge('lint', [w('src/a.ts')]).ok).toBe(true);
    for (const p of ['.github/workflows/ci.yml', '.env.example', 'wrangler.jsonc', 'db/migrations/1.sql', 'src/checkout.ts', 'tsconfig.json']) expect(diffAllowsAutoMerge('lint', [w(p)]).ok).toBe(false);
    expect(diffAllowsAutoMerge('test', [{ path: 'test/a.test.ts', type: 'delete' }]).ok).toBe(false);
    expect(diffAllowsAutoMerge('ci-failure', [w('README.md')]).ok).toBe(false);
  });
  it('packageJsonDepsOnly allows pnpm.overrides only', () => {
    expect(packageJsonDepsOnly('{"pnpm":{"overrides":{"a":"1"}}}', '{"pnpm":{"overrides":{"a":"2"}}}')).toBe(true);
    expect(packageJsonDepsOnly('{"pnpm":{}}', '{"pnpm":{"patchedDependencies":{"a":"x"}}}')).toBe(false);
    expect(packageJsonDepsOnly('{', '{}')).toBe(false);
  });
});

describe('scanSecrets', () => {
  it('names hits without echoing them; clean text passes', () => {
    expect(scanSecrets(`x ghp_${'a'.repeat(36)}`)).toEqual(['GitHub token']);
    expect(scanSecrets('-----BEGIN OPENSSH PRIVATE KEY-----')).toEqual(['private key']);
    expect(scanSecrets('const apiKey = "abcdefghijklmnopqrstuvwxyz123456"')).toEqual(['generic credential assignment']);
    expect(scanSecrets('Fixed the broken link in README.md.')).toEqual([]);
  });
});

describe('usage threshold (I-1)', () => {
  it('parseThreshold: unset = undefined; anything but a 1..100 number = null', () => {
    expect(parseThreshold(undefined)).toBeUndefined();
    expect(parseThreshold('80')).toBe(80);
    for (const v of ['', 'abc', 'NaN', '0', '101', '-5', '80%', '__PLACEHOLDER__']) expect(parseThreshold(v)).toBeNull();
  });
  it('decide and UsageGuard refuse on an invalid threshold even with a low reading', async () => {
    expect(decide({ src: 'x', pct: 1 }, Number.NaN).allowed).toBe(false);
    const g = new UsageGuard({ thresholdPct: Number.NaN, probe: async () => { throw new Error('must not probe'); } });
    expect(await g.check()).toMatchObject({ allowed: false, reason: expect.stringMatching(/invalid usage threshold/) });
  });
});

describe('agent-instruction and governance files never auto-merge (N-1)', () => {
  it('a docs change to CLAUDE.md / AGENTS.md / GEMINI.md / .claude / .agents / .cursor / .github / CODEOWNERS / .husky is refused', () => {
    for (const p of ['CLAUDE.md', 'apps/web/CLAUDE.md', 'AGENTS.md', 'docs/AGENTS.md', 'GEMINI.md', '.claude/settings.json', '.claude/agents/x.md', '.agents/skills/a/SKILL.md', '.cursor/rules/r.mdc', '.cursorrules', '.github/CODEOWNERS', '.github/copilot-instructions.md', 'CODEOWNERS', 'docs/CODEOWNERS', '.husky/pre-commit']) {
      expect(diffAllowsAutoMerge('docs', [w(p)]).ok, p).toBe(false);
    }
    expect(diffAllowsAutoMerge('docs', [w('docs/claude-notes.md')]).ok).toBe(true);
  });
  it('protectedFor: config globs (os/** in the foundation repo) and files the hands commands name', () => {
    const extra = protectedFor({ protectedPaths: ['os/**'], test: ['bash', './scripts/ci-test.sh', '--fast'], install: ['npm', 'ci'], mergeGate: ['bash', '{os_home}/ops/merge-gate.sh', '{pr}'] });
    expect(diffAllowsAutoMerge('docs', [w('os/standard/x.md')], extra).ok).toBe(false);
    expect(diffAllowsAutoMerge('lint', [w('scripts/ci-test.sh')], extra).ok).toBe(false);
    expect(diffAllowsAutoMerge('docs', [w('docs/os.md')], extra).ok).toBe(true);
    expect(globToRegExp('docs/*.md').test('docs/a/b.md')).toBe(false);
  });
});
