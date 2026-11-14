import { describe, expect, it } from 'vitest';
import { execFileSync, spawnSync } from 'node:child_process';
import { appendFileSync, cpSync, mkdtempSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
// @ts-expect-error plain .mjs without types
import { check, sync } from '../lib/foundation.mjs';

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
    expect(lock.tag).toBe('v0.2.0');
    expect(lock.commit).toMatch(/^[0-9a-f]{40}$/);
    expect(Object.keys(lock.files)).toContain('vendor/foundation/phone.ts');
    expect(Object.keys(lock.files).some((f) => f.endsWith('.test.ts') && f.includes('vendor/foundation/'))).toBe(false);
    expect(check(target)).toEqual([]);
  });
  it('sync vendors the capability module set and check passes', () => {
    for (const m of ['capability', 'capability-registry', 'ratchet', 'capability-coverage', 'self-service-routes', 'smart-layer-bypass', 'help-article']) {
      expect(Object.keys(lock.files)).toContain(`vendor/foundation/${m}.ts`);
    }
    expect(Object.keys(lock.files).some((f) => f.endsWith('capability.test.ts'))).toBe(false);
    expect(check(target)).toEqual([]);
  });
  it('editing one byte fails check, naming the file', () => {
    appendFileSync(join(target, 'vendor/foundation/phone.ts'), ' ');
    expect(check(target)).toEqual(['modified: vendor/foundation/phone.ts']);
    sync({ target, dir: 'vendor/foundation', parity: 'test/foundation-parity.test.ts', root: src });
    expect(check(target)).toEqual([]);
  });
  it('an extra file under the vendored dir fails check', () => {
    writeFileSync(join(target, 'vendor/foundation/extra.ts'), 'x');
    expect(check(target)).toEqual(['extra file not in the lock: vendor/foundation/extra.ts']);
    rmSync(join(target, 'vendor/foundation/extra.ts'));
  });
  it('a missing file fails check', () => {
    rmSync(join(target, 'vendor/foundation/vectors/slugs.json'));
    expect(check(target)).toEqual(['missing: vendor/foundation/vectors/slugs.json']);
  });
  it('a refused dirty foundation checkout', () => {
    appendFileSync(join(src, 'packages/foundation/src/phone.ts'), '\n');
    expect(() => sync({ target, dir: 'v', parity: 'p.test.ts', root: src })).toThrow(/uncommitted/);
  });
});

describe('ebda-foundation capabilities', () => {
  const bin = join(ROOT, 'bin/ebda-foundation.mjs');
  const node = (...a: string[]) => spawnSync('node', [bin, 'capabilities', ...a], { encoding: 'utf8' });
  const cat = join(ROOT, 'test/fixtures/capability/store-mini.json');
  it('seed writes files, exits 0 and prints the report counts', () => {
    const out = mkdtempSync(join(tmpdir(), 'cli-cap-'));
    const r = node('seed', '--product', 'store', '--catalogue', cat, '--out', out, '--today', '2026-11-14');
    expect(r.status).toBe(0);
    expect(r.stdout).toMatch(/written 8, skipped 0/);
    expect(r.stdout).toMatch(/needsHelp \d+/);
    expect(readdirSync(out)).toHaveLength(8);
    expect(node('seed', '--product', 'store', '--catalogue', cat, '--out', out).stdout).toMatch(/written 0, skipped 8/);
  });
  it('backfill-plan prints the batches as json', () => {
    const out = mkdtempSync(join(tmpdir(), 'cli-cap-'));
    node('seed', '--product', 'store', '--catalogue', cat, '--out', out);
    const cfg = join(out, '..', 'guard.config.json');
    writeFileSync(cfg, JSON.stringify({ helpExemptAreas: ['platform'] }));
    const r = node('backfill-plan', '--dir', out, '--config', cfg);
    expect(r.status).toBe(0);
    expect(JSON.parse(r.stdout).batches.length).toBeGreaterThan(0);
  });
  it('scaffold prints an mdx skeleton for one id', () => {
    const out = mkdtempSync(join(tmpdir(), 'cli-cap-'));
    node('seed', '--product', 'store', '--catalogue', cat, '--out', out);
    const r = node('scaffold', '--dir', out, '--id', 'onboarding.signup', '--lang', 'en');
    expect(r.status).toBe(0);
    expect(r.stdout).toContain('capabilities:\n  - onboarding.signup@1');
  });
  it('bad usage exits 2', () => {
    expect(node('seed', '--product', 'store').status).toBe(2);
    expect(node('nope').status).toBe(2);
  });
});
