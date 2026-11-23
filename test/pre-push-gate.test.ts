import { describe, expect, it } from 'vitest';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

const GATE = resolve(__dirname, '../ops/pre-push-gate.sh');
const git = (cwd: string, ...a: string[]) => execFileSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@t', ...a], { cwd, encoding: 'utf8' });

/** A repo with an origin/main merge base and one changed .txt file (prettier ignores it, so no node_modules is needed). */
function repo(): string {
  const d = mkdtempSync(join(tmpdir(), 'pp-'));
  git(d, 'init', '-q', '-b', 'main');
  writeFileSync(join(d, 'a.txt'), 'a');
  writeFileSync(join(d, '.gitleaks.toml'), '[extend]\nuseDefault = true\n'); // gitleaks (when installed) refuses to run without the repo config
  git(d, 'add', 'a.txt', '.gitleaks.toml');
  git(d, 'commit', '-qm', 'base');
  git(d, 'update-ref', 'refs/remotes/origin/main', 'HEAD');
  writeFileSync(join(d, 'b.txt'), 'b');
  git(d, 'add', 'b.txt');
  git(d, 'commit', '-qm', 'change');
  return d;
}
const run = (cwd: string, env: Record<string, string> = {}) => {
  const r = spawnSync('bash', [GATE], { cwd, encoding: 'utf8', env: { ...process.env, PATH: process.env.PATH ?? '', ...env } });
  return { status: r.status, out: r.stdout + r.stderr };
};

describe('pre-push-gate.sh', () => {
  it('passes on a clean push and prints the OK line', () => {
    const r = run(repo(), { PRE_PUSH_ACTION_PINS: '', PRE_PUSH_EXTRA: '' });
    expect(r.status).toBe(0);
    expect(r.out).toContain('OK light pre-push gate passed');
  });
  it('no merge base with origin/main -> exits 0 and leaves the scans to CI (the extra hook does not run)', () => {
    const d = mkdtempSync(join(tmpdir(), 'pp-'));
    git(d, 'init', '-q', '-b', 'main');
    writeFileSync(join(d, 'x.txt'), 'x');
    git(d, 'add', 'x.txt');
    git(d, 'commit', '-qm', 'one');
    mkdirSync(join(d, 'scripts/ci'), { recursive: true });
    writeFileSync(join(d, 'scripts/ci/pre-push-extra.sh'), 'exit 9\n');
    const r = run(d, { PRE_PUSH_ACTION_PINS: '' });
    expect(r.status).toBe(0);
    expect(r.out).toContain('no merge base with origin/main');
  });
  it('the action-pin script is REQUIRED: missing -> the gate fails (a declared gate must not fail open); failing -> fails', () => {
    const d = repo();
    expect(run(d, { PRE_PUSH_EXTRA: '' }).status).not.toBe(0);
    writeFileSync(join(d, 'pins.sh'), 'echo unpinned >&2; exit 1\n');
    const r = run(d, { PRE_PUSH_ACTION_PINS: 'pins.sh', PRE_PUSH_EXTRA: '' });
    expect(r.status).toBe(1);
    expect(r.out).toContain('unpinned');
    writeFileSync(join(d, 'pins.sh'), 'exit 0\n');
    expect(run(d, { PRE_PUSH_ACTION_PINS: 'pins.sh', PRE_PUSH_EXTRA: '' }).status).toBe(0);
  });
  it('runs the product hook LAST with BASE exported; its failure fails the gate', () => {
    const d = repo();
    const base = git(d, 'merge-base', 'origin/main', 'HEAD').trim();
    mkdirSync(join(d, 'scripts/ci'), { recursive: true });
    writeFileSync(join(d, 'scripts/ci/pre-push-extra.sh'), 'echo "extra BASE=$BASE"\n');
    const ok = run(d, { PRE_PUSH_ACTION_PINS: '' });
    expect(ok.status).toBe(0);
    expect(ok.out).toContain(`extra BASE=${base}`);
    expect(ok.out.indexOf('extra BASE')).toBeLessThan(ok.out.indexOf('OK light pre-push gate passed'));
    writeFileSync(join(d, 'scripts/ci/pre-push-extra.sh'), 'echo extra-failed >&2; exit 4\n');
    const bad = run(d, { PRE_PUSH_ACTION_PINS: '' });
    expect(bad.status).toBe(4);
    expect(bad.out).not.toContain('OK light pre-push gate passed');
  });
});
