import { describe, expect, it } from 'vitest';
import { execFileSync } from 'node:child_process';
import { appendFileSync, cpSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
// @ts-expect-error plain .mjs without types
import { check, sync } from '../bin/ebda-foundation.mjs';

const ROOT = resolve(__dirname, '..');
const g = (cwd: string, ...a: string[]) => execFileSync('git', a, { cwd, encoding: 'utf8' });

// sync needs a clean committed foundation checkout (the lock records its commit): make a throwaway clone of the working tree's files.
function fixtureFoundation(): string {
  const d = mkdtempSync(join(tmpdir(), 'fnd-src-'));
  for (const p of ['packages', 'vectors', 'parity']) cpSync(join(ROOT, p), join(d, p), { recursive: true, filter: (s) => !s.includes('node_modules') });
  g(d, 'init', '-q');
  g(d, '-c', 'user.name=t', '-c', 'user.email=t@t', 'add', '.');
  g(d, '-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qm', 'fixture');
  return d;
}

describe('ebda-foundation sync/check', () => {
  const src = fixtureFoundation();
  const target = mkdtempSync(join(tmpdir(), 'fnd-tgt-'));
  const lock = sync({ target, dir: 'vendor/foundation', parity: 'test/foundation-parity.test.ts', root: src });

  it('sync writes the lock and check passes', () => {
    expect(lock.tag).toBe('v0.1.0');
    expect(lock.commit).toMatch(/^[0-9a-f]{40}$/);
    expect(Object.keys(lock.files)).toContain('vendor/foundation/src/phone/index.ts');
    expect(Object.keys(lock.files).some((f) => f.endsWith('.test.ts') && f.includes('vendor/foundation/'))).toBe(false);
    expect(check(target)).toEqual([]);
  });
  it('editing one byte fails check, naming the file', () => {
    appendFileSync(join(target, 'vendor/foundation/src/phone/index.ts'), ' ');
    expect(check(target)).toEqual(['modified: vendor/foundation/src/phone/index.ts']);
    sync({ target, dir: 'vendor/foundation', parity: 'test/foundation-parity.test.ts', root: src });
    expect(check(target)).toEqual([]);
  });
  it('an extra file under the vendored dir fails check', () => {
    writeFileSync(join(target, 'vendor/foundation/src/phone/extra.ts'), 'x');
    expect(check(target)).toEqual(['extra file not in the lock: vendor/foundation/src/phone/extra.ts']);
    rmSync(join(target, 'vendor/foundation/src/phone/extra.ts'));
  });
  it('a missing file fails check', () => {
    rmSync(join(target, 'vendor/foundation/vectors/slugs.json'));
    expect(check(target)).toEqual(['missing: vendor/foundation/vectors/slugs.json']);
  });
  it('a refused dirty foundation checkout', () => {
    appendFileSync(join(src, 'packages/foundation/src/phone/index.ts'), '\n');
    expect(() => sync({ target, dir: 'v', parity: 'p.test.ts', root: src })).toThrow(/uncommitted/);
  });
});

describe('the parity template, run inside a synced consumer fixture', () => {
  it('passes on a fresh sync and fails when the vendored code is edited', () => {
    const src = fixtureFoundation();
    const target = mkdtempSync(join(tmpdir(), 'fnd-par-'));
    sync({ target, dir: 'vendor/foundation', parity: 'test/foundation-parity.test.ts', root: src });
    execFileSync('ln', ['-s', join(ROOT, 'node_modules'), join(target, 'node_modules')]);
    const run = () => execFileSync(join(ROOT, 'node_modules/.bin/vitest'), ['run', '--root', target, '--dir', 'test'], { encoding: 'utf8', stdio: 'pipe' });
    expect(run()).toContain('passed');
    appendFileSync(join(target, 'vendor/foundation/vectors/phone.json'), ' ');
    expect(() => run()).toThrow();
  }, 60_000);
});
