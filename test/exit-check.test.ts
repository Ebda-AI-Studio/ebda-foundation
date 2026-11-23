import { describe, it, expect } from 'vitest';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, writeFileSync, chmodSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const SCRIPT = join(__dirname, '../loop/exit-check.sh');
const SHA = 'a'.repeat(40);

// gh and curl are stubbed on PATH; every knob is an env var the stub reads, so a case changes ONE fact.
function run(env: Record<string, string>, args: string[] = []) {
  const bin = mkdtempSync(join(tmpdir(), 'xc-'));
  const stub = (name: string, body: string) => { writeFileSync(join(bin, name), `#!/bin/bash\n${body}\n`); chmodSync(join(bin, name), 0o755); };
  stub('gh', `a="$*"
case "$a" in
  *"issue list"*) echo "\${X_ISSUES:-0}";;
  *"commits/main"*) echo ${SHA};;
  *"check-runs"*"total_count"*) echo 5;;
  *"check-runs"*) echo "\${X_BADCHECKS:-}";;
  *compare*) echo "\${X_DIFF:-README.md}";;
  *"run list"*) echo "\${X_RUNS:-success,success,success}";;
esac`);
  stub('curl', `a="$*"
case "$a" in
  */health*) echo '{"commit":"'\${X_LIVE:-${SHA}}'"}';;
  */api/state*) echo '{"findings":{"open":'\${X_OPEN:-0}'}}';;
  */api/alerts*) echo '{"alerts":[]}';;
esac`);
  // A Keychain whose only item has account $USER (not a hard-coded name): a lookup that passes a different -a misses it.
  stub('security', `[ "$1" = find-generic-password ] || exit 2
acct=""; svc=""
while [ $# -gt 0 ]; do case "$1" in -a) acct="$2"; shift;; -s) svc="$2"; shift;; esac; shift; done
[ "$svc" = ebda-os-dash ] || exit 44
[ -z "$acct" ] || [ "$acct" = "$USER" ] || exit 44
echo "kc-secret"`);
  return spawnSync('bash', [SCRIPT, ...args], {
    env: { PATH: `${bin}:/usr/bin:/bin`, EBDA_OS_DASH_PASSWORD: 'x', EXIT_REPOS: 'o/r', EXIT_MAIN_REPO: 'o/r', EXIT_HEALTH: 'api|https://h/health|apps/api', ...env },
    encoding: 'utf8',
  });
}

describe('loop/exit-check.sh', () => {
  it('all measured pass: still exits 1 until the manual conditions are asserted', () => {
    const r = run({});
    expect(r.stdout).not.toMatch(/FAIL/);
    expect(r.stdout).toMatch(/manual: needs controller evidence {2}5 /);
    expect(r.status).toBe(1);
  });
  it('--manual-ok with everything measured green exits 0', () => {
    expect(run({}, ['--manual-ok']).status).toBe(0);
  });
  it('an open review-finding issue fails 3a, even with --manual-ok', () => {
    const r = run({ X_ISSUES: '2' }, ['--manual-ok']);
    expect(r.stdout).toMatch(/FAIL {2}3a/);
    expect(r.status).toBe(1);
  });
  it('a failing check on main fails 4a', () => {
    expect(run({ X_BADCHECKS: 'Build' }, ['--manual-ok']).stdout).toMatch(/FAIL {2}4a.*Build/);
  });
  it('4b: a stale live commit fails only when main changed that app since', () => {
    const live = 'b'.repeat(40);
    expect(run({ X_LIVE: live, X_DIFF: 'apps/api/x.ts' }).stdout).toMatch(/FAIL {2}4b api/);
    expect(run({ X_LIVE: live, X_DIFF: 'apps/web/x.ts' }).stdout).toMatch(/PASS {2}4b api/);
  });
  it('4c needs three successes; 6 fails on any open finding', () => {
    expect(run({ X_RUNS: 'success,failure,success' }).stdout).toMatch(/FAIL {2}4c/);
    expect(run({ X_OPEN: '1' }).stdout).toMatch(/FAIL {2}6 brain: 1 open/);
  });
  it('6 reads the Keychain item by service, whatever its account (USER=ahmadsharaf, not "ahmad")', () => {
    const r = run({ EBDA_OS_DASH_PASSWORD: '', USER: 'ahmadsharaf' });
    expect(r.stdout).not.toMatch(/no dashboard password/);
    expect(r.stdout).toMatch(/PASS {2}6 brain/);
  });
  it('4b web: a packages/repo change does not make web "behind"; packages/ui does', () => {
    const live = 'b'.repeat(40);
    const web = { X_LIVE: live, EXIT_HEALTH: 'web|https://h/health|apps/web packages/shared packages/ui' };
    expect(run({ ...web, X_DIFF: 'packages/repo/x.ts' }).stdout).toMatch(/PASS {2}4b web/);
    expect(run({ ...web, X_DIFF: 'packages/ui/x.ts' }).stdout).toMatch(/FAIL {2}4b web/);
  });
  it('the DEFAULT web/admin prefixes equal the deploy workflows filters (no bare "packages")', () => {
    const r = run({ EXIT_HEALTH: '', X_LIVE: 'b'.repeat(40), X_DIFF: 'packages/repo/x.ts' });
    expect(r.stdout).toMatch(/PASS {2}4b web/);
    expect(r.stdout).toMatch(/PASS {2}4b admin/);
    expect(r.stdout).toMatch(/FAIL {2}4b api/);
  });
});
