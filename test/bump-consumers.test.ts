import { describe, expect, it } from 'vitest';
import { execFileSync } from 'node:child_process';
import { chmodSync, cpSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
// @ts-expect-error plain .mjs without types
import { cmpTag, decide, prBody, run } from '../ops/bump-consumers.mjs';
// @ts-expect-error plain .mjs without types
import { check, sync } from '../lib/foundation.mjs';

const ROOT = resolve(__dirname, '..');
const g = (cwd: string, ...a: string[]) => execFileSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@t', ...a], { cwd, encoding: 'utf8' });
const version = JSON.parse(readFileSync(join(ROOT, 'packages/foundation/package.json'), 'utf8')).version as string;
const TAG = `v${version}`;

function fixtureFoundation(): string {
  const d = mkdtempSync(join(tmpdir(), 'bump-src-'));
  for (const p of ['packages', 'vectors', 'parity']) cpSync(join(ROOT, p), join(d, p), { recursive: true, filter: (s) => !s.includes('node_modules') });
  g(d, 'init', '-q');
  g(d, 'add', '.');
  g(d, 'commit', '-qm', 'fixture');
  return d;
}

function consumer(tag: string): string {
  const d = mkdtempSync(join(tmpdir(), 'bump-consumer-'));
  writeFileSync(join(d, 'foundation.lock.json'), JSON.stringify({ tag, commit: 'a'.repeat(40), dir: 'vendor/foundation', parity: 'test/foundation-parity.test.ts', files: {}, managed: [] }));
  return d;
}

/** A fake `gh`: records every call to $FAKE_LOG; answers `api` with FAKE_LOCK, `pr list` with FAKE_PRS, and `pr create` with a URL. */
function fakeGh(): string {
  const d = mkdtempSync(join(tmpdir(), 'bump-gh-'));
  const p = join(d, 'gh');
  writeFileSync(p, '#!/bin/sh\necho "$@" >> "$FAKE_LOG"\ncase "$1" in\n api) echo "$FAKE_LOCK";;\n pr) case "$2" in list) printf "%b" "$FAKE_PRS";; create) echo https://example.test/pull/1;; esac;;\nesac\n');
  chmodSync(p, 0o755);
  return p;
}

const lines = (f: (log: (s: string) => void) => Promise<unknown>) => {
  const out: string[] = [];
  return f((s) => out.push(s)).then(() => out);
};

describe('decide', () => {
  it('opens only when behind with no open PR for the tag', () => {
    expect(decide({ lockTag: 'v0.3.2', tag: 'v0.3.4', open: [], others: [948] })).toEqual({ action: 'open', supersedes: [948] });
    expect(decide({ lockTag: 'v0.3.4', tag: 'v0.3.4', open: [], others: [] }).action).toBe('skip');
    expect(decide({ lockTag: 'v0.3.2', tag: 'v0.3.4', open: [7], others: [] }).action).toBe('skip');
    expect(decide({ lockTag: 'v0.4.0', tag: 'v0.3.4', open: [], others: [] }).why).toMatch(/never downgrades/);
    expect(decide({ lockTag: undefined, tag: 'v0.3.4', open: [], others: [] }).action).toBe('skip');
  });
  it('compares tags numerically (v0.3.10 > v0.3.9)', () => {
    expect(cmpTag('v0.3.10', 'v0.3.9')).toBe(1);
    expect(cmpTag('v1.0.0', 'v0.99.99')).toBe(1);
  });
});

describe('prBody', () => {
  it('has the three sections pr-quality requires and flags problems', () => {
    const b = prBody({ name: 'ebda-store', from: 'v0.3.2', to: 'v0.3.4', problems: ['peer dependency zod@4.6.7 is not declared'], supersedes: [948], commit: 'b'.repeat(40) });
    for (const h of ['## What', '## Verified', '## Not verified', '## Cost-if-wrong']) expect(b).toContain(h);
    expect(b).toContain('draft');
    expect(b).toContain('#948');
    expect(prBody({ name: 'x', from: 'v0.3.2', to: 'v0.3.4', problems: [], supersedes: [], commit: 'b'.repeat(40) })).toContain('in sync, 0 problems');
  });
});

describe('dry run', () => {
  it('prints the PR it would open for the stale consumer and nothing for the current one, writing nothing', async () => {
    const store = consumer('v0.3.2');
    const wa = consumer(TAG);
    const out = await lines((log) => run(['--dry-run', '--consumer-dir', `ebda-store=${store}`, '--consumer-dir', `ebda-whatsapp=${wa}`], log));
    expect(out.join('\n')).toContain(`WOULD OPEN PR Ebda-AI-Studio/ebda-store: v0.3.2 -> ${TAG}`);
    expect(out.join('\n')).toContain(`ebda-whatsapp: already on ${TAG}; nothing to do`);
    expect(out.at(-1)).toBe('would open 1, failed 0');
    expect(readFileSync(join(store, 'foundation.lock.json'), 'utf8')).toContain('v0.3.2');
  });
  it('opens nothing when both consumers are on the latest tag', async () => {
    const out = await lines((log) => run(['--dry-run', '--consumer-dir', `ebda-store=${consumer(TAG)}`, '--consumer-dir', `ebda-whatsapp=${consumer(TAG)}`], log));
    expect(out.at(-1)).toBe('would open 0, failed 0');
    expect(out.join('\n')).not.toContain('WOULD OPEN');
  });
  it('refuses a target tag that is not the checked-out foundation', async () => {
    await expect(run(['--dry-run', '--tag', 'v9.9.9'], () => {})).rejects.toThrow(/check the tag out first/);
  });
  it('reads remote locks and open PRs through gh: skips a consumer with an open PR, notes superseded ones', async () => {
    process.env.EBDA_BUMP_GH = fakeGh();
    process.env.FAKE_LOG = join(mkdtempSync(join(tmpdir(), 'bump-log-')), 'calls');
    process.env.FAKE_LOCK = JSON.stringify({ tag: 'v0.3.2', dir: 'packages/shared/src/foundation', parity: 'tests/unit/foundation-parity.test.ts' });
    try {
      process.env.FAKE_PRS = '948\\n';
      let out = await lines((log) => run(['--dry-run', '--consumers', 'ebda-store=Ebda-AI-Studio/ebda-store'], log));
      expect(out.join('\n')).toContain('open PR #948 already bumps'); // fake gh answers every list with 948 (head match)
      process.env.FAKE_PRS = '';
      out = await lines((log) => run(['--dry-run', '--consumers', 'ebda-store=Ebda-AI-Studio/ebda-store'], log));
      expect(out.join('\n')).toContain('WOULD OPEN PR Ebda-AI-Studio/ebda-store');
      const calls = readFileSync(process.env.FAKE_LOG, 'utf8');
      expect(calls).not.toMatch(/pr create|repo clone|label create/); // a dry run never writes
    } finally {
      for (const k of ['EBDA_BUMP_GH', 'FAKE_LOG', 'FAKE_LOCK', 'FAKE_PRS']) delete process.env[k];
    }
  });
});

describe('apply (local consumer, bare remote, fake gh)', () => {
  it('branches, re-vendors via sync using the consumer lock paths, pushes, and opens a labelled PR; never merges', async () => {
    const src = fixtureFoundation();
    const bare = mkdtempSync(join(tmpdir(), 'bump-bare-'));
    g(bare, 'init', '-q', '--bare');
    const store = mkdtempSync(join(tmpdir(), 'bump-store-'));
    g(store, 'init', '-q', '-b', 'main');
    sync({ target: store, dir: 'vendor/foundation', parity: 'test/foundation-parity.test.ts', root: src });
    const lock = JSON.parse(readFileSync(join(store, 'foundation.lock.json'), 'utf8'));
    writeFileSync(join(store, 'foundation.lock.json'), JSON.stringify({ ...lock, tag: 'v0.3.2' }, null, 2));
    mkdirSync(join(store, 'vendor/foundation'), { recursive: true });
    writeFileSync(join(store, 'vendor/foundation/old-only.ts'), '// stale file the sync must remove\n');
    g(store, 'add', '.');
    g(store, 'commit', '-qm', 'old');
    g(store, 'remote', 'add', 'origin', bare);
    g(store, 'push', '-q', 'origin', 'main');
    process.env.EBDA_BUMP_GH = fakeGh();
    process.env.FAKE_LOG = join(mkdtempSync(join(tmpdir(), 'bump-log-')), 'calls');
    try {
      const out = await lines((log) => run(['--consumers', 'ebda-store=Ebda-AI-Studio/ebda-store', '--consumer-dir', `ebda-store=${store}`], log, { root: src }));
      expect(out.join('\n')).toContain('ebda-store: opened https://example.test/pull/1');
      expect(g(bare, 'branch', '--list', `chore/foundation-${TAG}`)).toContain(`chore/foundation-${TAG}`);
      expect(check(store)).toEqual([]);
      expect(JSON.parse(readFileSync(join(store, 'foundation.lock.json'), 'utf8')).tag).toBe(TAG);
      const calls = readFileSync(process.env.FAKE_LOG, 'utf8');
      expect(calls).toMatch(/pr create .*--label foundation-bump/);
      expect(calls).not.toMatch(/^pr merge/m);
      // second run: the branch is on the remote and the lock is current -> nothing more
      const again = await lines((log) => run(['--consumers', 'ebda-store=Ebda-AI-Studio/ebda-store', '--consumer-dir', `ebda-store=${store}`], log, { root: src }));
      expect(again.join('\n')).toContain('nothing to do');
    } finally {
      delete process.env.EBDA_BUMP_GH;
      delete process.env.FAKE_LOG;
    }
  });
});
