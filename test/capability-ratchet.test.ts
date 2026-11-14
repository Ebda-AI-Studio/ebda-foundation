import { describe, expect, it } from 'vitest';
import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

const SCRIPT = resolve(__dirname, '../ci/pr-quality/capability-ratchet.mjs');
function tree(files: Record<string, string[]> | null): string {
  const d = mkdtempSync(join(tmpdir(), 'cap-rat-'));
  if (files) {
    mkdirSync(join(d, 'capabilities/baselines'), { recursive: true });
    for (const [n, ids] of Object.entries(files)) writeFileSync(join(d, 'capabilities/baselines', n), JSON.stringify({ ids }));
  }
  return d;
}
const run = (base: string, pr: string) => spawnSync('node', [SCRIPT, '--base', base, '--pr', pr], { encoding: 'utf8' });

describe('capability-ratchet', () => {
  it('fails and names the id when the PR baseline gains one', () => {
    const r = run(tree({ 'help.json': ['a|1'] }), tree({ 'help.json': ['a|1', 'a|hide-me'] }));
    expect(r.status).toBe(1);
    expect(r.stderr).toContain('a|hide-me');
  });
  it('passes when the PR only loses ids', () => expect(run(tree({ 'help.json': ['a|1', 'a|2'] }), tree({ 'help.json': ['a|1'] })).status).toBe(0));
  it('passes when the base has no baselines (adoption PR)', () => expect(run(tree(null), tree({ 'help.json': ['a|1'] })).status).toBe(0));
  it('refuses a symlinked baseline', () => {
    const pr = tree({ 'help.json': [] });
    const out = join(pr, 'outside.json');
    writeFileSync(out, JSON.stringify({ ids: ['x'] }));
    mkdirSync(join(pr, 'capabilities/baselines'), { recursive: true });
    symlinkSync(out, join(pr, 'capabilities/baselines/evil.json'));
    const base = tree({ 'evil.json': [] });
    expect(run(base, pr).status).not.toBe(0);
  });
  it('usage error exits 2', () => expect(spawnSync('node', [SCRIPT], { encoding: 'utf8' }).status).toBe(2));
});

describe('capability-ratchet hardening', () => {
  const raw = (files: Record<string, unknown>): string => {
    const d = mkdtempSync(join(tmpdir(), 'cap-rat-'));
    mkdirSync(join(d, 'capabilities/baselines'), { recursive: true });
    for (const [n, body] of Object.entries(files)) writeFileSync(join(d, 'capabilities/baselines', n), JSON.stringify(body));
    return d;
  };
  it('after adoption a NEW baseline file with ids is rejected; an empty one is allowed', () => {
    const base = tree({ 'help.json': ['a|1'] });
    const bad = run(base, tree({ 'help.json': ['a|1'], 'fresh.json': ['x|hidden'] }));
    expect(bad.status).toBe(1);
    expect(bad.stderr).toContain('x|hidden');
    expect(run(base, tree({ 'help.json': ['a|1'], 'fresh.json': [] })).status).toBe(0);
  });
  it('a baseline without an ids array is invalid, not empty (PR side)', () => {
    const r = run(tree({ 'help.json': ['a|1'] }), raw({ 'help.json': { baseline: ['a|1', 'new'] } }));
    expect(r.status).toBe(1);
    expect(r.stderr).toMatch(/ids/);
  });
  it('a baseline without an ids array is invalid on the base side too, and a bare array is invalid', () => {
    expect(run(raw({ 'help.json': { baseline: [] } }), tree({ 'help.json': [] })).status).toBe(1);
    expect(run(tree({ 'help.json': [] }), raw({ 'help.json': ['a|1'] })).status).toBe(1);
  });
  it('the workflow job tolerates a base that has no script yet (the adoption PR)', () => {
    const y = readFileSync(resolve(__dirname, '../.github/workflows/pr-quality.yml'), 'utf8');
    expect(y).toMatch(/if \[ -f base\/\.github\/pr-quality\/capability-ratchet\.mjs \]/);
    expect(y).toMatch(/::notice::/);
  });
});
