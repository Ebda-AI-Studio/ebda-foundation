// Runs the parity template inside a freshly synced consumer fixture: it must pass, then fail after one byte of vendored data changes.
// A separate process (not a vitest test): vitest inside vitest hangs.
import { execFileSync } from 'node:child_process';
import { appendFileSync, cpSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { sync } from '../lib/foundation.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const git = (cwd, ...a) => execFileSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@t', ...a], { cwd, encoding: 'utf8' });
const src = mkdtempSync(join(tmpdir(), 'fnd-src-'));
for (const p of ['packages', 'vectors', 'parity']) cpSync(join(ROOT, p), join(src, p), { recursive: true, filter: (s) => !s.includes('node_modules') });
git(src, 'init', '-q'); git(src, 'add', '.'); git(src, 'commit', '-qm', 'fixture');
const target = mkdtempSync(join(tmpdir(), 'fnd-par-'));
sync({ target, dir: 'vendor/foundation', parity: 'test/foundation-parity.test.ts', root: src });
writeFileSync(join(target, 'package.json'), JSON.stringify({ name: 'fixture', private: true, devDependencies: { zod: '4.6.7' } }));
symlinkSync(join(ROOT, 'node_modules'), join(target, 'node_modules'));
const vitest = join(ROOT, 'node_modules/.bin/vitest');
const run = () => execFileSync(vitest, ['run'], { cwd: target, encoding: 'utf8', stdio: 'pipe' });
try {
  if (!run().includes('passed')) throw new Error('parity did not pass on a fresh sync');
  appendFileSync(join(target, 'vendor/foundation/vectors/phone.json'), ' ');
  let failed = false;
  try { run(); } catch { failed = true; }
  if (!failed) throw new Error('parity still passed after the vendored vectors were edited');
  console.log('parity fixture: passes on a fresh sync, fails after a 1-byte edit');
} finally {
  rmSync(src, { recursive: true, force: true }); rmSync(target, { recursive: true, force: true });
}
