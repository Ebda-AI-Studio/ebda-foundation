import { execFileSync, spawnSync } from 'node:child_process';
import { mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { afterAll, describe, expect, it } from 'vitest';

const CLI = resolve('bin/ebda-foundation.mjs');
const COMMIT = 'a'.repeat(40);
// Fixtures live inside the repo (git-ignored) so `vitest` resolves from the repo's node_modules.
const TMP = resolve('test/.tmp');
const run = (args: string[], env: Record<string, string> = {}) =>
  spawnSync('node', [CLI, ...args], { encoding: 'utf8', env: { ...process.env, ...env } });
let n = 0;
const fixture = () => {
  const d = join(TMP, `fx${process.pid}-${n++}`);
  rmSync(d, { recursive: true, force: true });
  mkdirSync(d, { recursive: true });
  return d;
};
afterAll(() => rmSync(TMP, { recursive: true, force: true }));

describe('ebda-foundation sync / check', () => {
  it('sync into a fixture, check passes, a 1-byte edit fails naming the file', () => {
    const d = fixture();
    const s = run(['sync', '--target', d, '--commit', COMMIT]);
    expect(s.status, s.stderr).toBe(0);
    const lock = JSON.parse(readFileSync(join(d, 'foundation.lock.json'), 'utf8'));
    expect(lock.tag).toMatch(/^v\d+\.\d+\.\d+$/);
    expect(lock.commit).toBe(COMMIT);
    expect(Object.keys(lock.files)).toContain('foundation/src/phone/index.ts');
    expect(Object.keys(lock.files)).toContain('foundation/vectors/buyer-key.json');
    expect(Object.keys(lock.files)).toContain('scripts/foundation/merge-gate.sh');
    expect(Object.keys(lock.files).some((f) => f.endsWith('.test.ts') && f.includes('/src/'))).toBe(false);
    expect(run(['check', '--target', d]).status).toBe(0);

    const f = join(d, 'foundation/src/phone/index.ts');
    writeFileSync(f, readFileSync(f, 'utf8') + ' ');
    const bad = run(['check', '--target', d]);
    expect(bad.status).toBe(1);
    expect(bad.stderr).toContain('MODIFIED foundation/src/phone/index.ts');
  });
  it('flags a missing file and an extra file', () => {
    const d = fixture();
    run(['sync', '--target', d, '--commit', COMMIT]);
    rmSync(join(d, 'foundation/vectors/slugs.json'));
    writeFileSync(join(d, 'foundation/src/extra.ts'), 'x');
    const r = run(['check', '--target', d]);
    expect(r.status).toBe(1);
    expect(r.stderr).toContain('MISSING foundation/vectors/slugs.json');
    expect(r.stderr).toContain('EXTRA foundation/src/extra.ts');
  });
  it('a re-sync repairs the copy and leaves one lock', () => {
    const d = fixture();
    run(['sync', '--target', d, '--commit', COMMIT]);
    writeFileSync(join(d, 'foundation/src/phone/index.ts'), 'tampered');
    expect(run(['sync', '--target', d, '--commit', COMMIT]).status).toBe(0);
    expect(run(['check', '--target', d]).status).toBe(0);
  });
  it('--to must equal this checkout tag; a dirty checkout needs --allow-dirty or --commit', () => {
    const d = fixture();
    expect(run(['sync', '--target', d, '--commit', COMMIT, '--to', 'v9.9.9']).status).toBe(1);
    expect(run(['sync', '--target', d, '--commit', 'zz']).status).toBe(64);
  });
  it('the vendored parity test passes in the fixture and fails after a 1-byte edit', () => {
    const d = fixture();
    run(['sync', '--target', d, '--commit', COMMIT]);
    const vitest = (cwd: string) => spawnSync('npx', ['vitest', 'run', '--root', cwd, '--dir', cwd], { encoding: 'utf8', env: { ...process.env, FOUNDATION_ROOT: cwd } });
    const ok = vitest(d);
    expect(ok.status, ok.stdout + ok.stderr).toBe(0);
    const f = join(d, 'foundation/vectors/phone.json');
    writeFileSync(f, readFileSync(f, 'utf8') + ' ');
    const bad = vitest(d);
    expect(bad.status).toBe(1);
    expect(bad.stdout + bad.stderr).toContain('MODIFIED foundation/vectors/phone.json');
  }, 60_000);
});

describe('ebda-foundation status', () => {
  it('prints tags, latest and skew', () => {
    const a = fixture(), b = fixture();
    run(['sync', '--target', a, '--commit', COMMIT]);
    const lockB = join(b, 'foundation.lock.json');
    writeFileSync(lockB, JSON.stringify({ tag: 'v0.0.1' }));
    const r = run(['status', a, b, '--latest', 'v9.0.0']);
    expect(r.status).toBe(0);
    expect(r.stdout).toMatch(/v0\.\d+\.\d+ · .* v0\.0\.1 · latest v9\.0\.0 · skew /);
  });
  it('workflow-lint is clean on this repo and flags a bad workflow', async () => {
    const { lintWorkflow } = await import(resolve('ops/workflow-lint.mjs'));
    const bad = lintWorkflow('x.yml', 'on:\n  pull_request:\njobs:\n  a:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/checkout@v4\n');
    expect(bad.join('\n')).toMatch(/concurrency/);
    expect(bad.join('\n')).toMatch(/timeout-minutes/);
    expect(bad.join('\n')).toMatch(/runs-on must be exactly/);
    expect(bad.join('\n')).toMatch(/40-hex/);
    expect(execFileSync('node', ['ops/workflow-lint.mjs', '.github/workflows'], { encoding: 'utf8' })).toContain('clean');
  });
});
