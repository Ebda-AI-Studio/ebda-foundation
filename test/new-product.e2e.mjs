// Slow tier (network: installs wrangler). `npm run test:new`; nightly in CI.
// Scaffolds ebda-sandbox without a remote and proves the finish line: npm ci, typecheck, test, wrangler deploy --dry-run.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { tmpdir } from 'node:os';

const CLI = resolve('bin/ebda-foundation.mjs');
const commit = execFileSync('git', ['rev-parse', 'HEAD'], { encoding: 'utf8' }).trim();

test('new ebda-sandbox --no-remote passes npm ci, typecheck, test and wrangler deploy --dry-run', { timeout: 15 * 60_000 }, () => {
  const base = mkdtempSync(join(tmpdir(), 'ebda-new-'));
  const dest = join(base, 'ebda-sandbox');
  try {
    execFileSync('node', [CLI, 'new', 'ebda-sandbox', '--no-remote', '--dest', dest, '--commit', commit], { stdio: 'inherit' });
    for (const f of ['foundation.lock.json', 'wrangler.jsonc', 'package-lock.json', 'CLAUDE.md', 'test/foundation-parity.test.ts', 'scripts/foundation/merge-gate.sh', '.github/workflows/ci.yml']) {
      assert.ok(existsSync(join(dest, f)), `scaffold is missing ${f}`);
    }
    assert.ok(!readFileSync(join(dest, 'wrangler.jsonc'), 'utf8').includes('__'), 'unfilled placeholder in wrangler.jsonc');
    const run = (cmd, args) => execFileSync(cmd, args, { cwd: dest, stdio: 'inherit', env: { ...process.env, CI: '1' } });
    run('npm', ['ci', '--no-audit', '--no-fund']);
    run('npm', ['run', 'typecheck']);
    run('npm', ['test']);
    run('npm', ['run', 'lint:workflows']);
    run('npx', ['wrangler', 'deploy', '--dry-run']);
    execFileSync('node', [CLI, 'check', '--target', dest], { stdio: 'inherit' });
  } finally {
    rmSync(base, { recursive: true, force: true });
  }
});
