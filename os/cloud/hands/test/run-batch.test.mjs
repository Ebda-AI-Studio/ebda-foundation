// End to end without network: run-batch --dry-run walks the fixture through the real pipeline; the example config
// validates; the Dockerfile passes the engine-free checks; providers obey the selection rules.
import { existsSync, readFileSync } from 'node:fs';
import { mkdir, mkdtemp, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { validateConfig } from '../lib/config.mjs';
import { main, sweepWorkdir } from '../run-batch.mjs';
import { checkDockerfile } from '../scripts/check-dockerfile.mjs';
import { selectProvider } from '../providers/index.mjs';

const HERE = join(import.meta.dirname, '..');

describe('run-batch --dry-run --fixture', () => {
  it('walks every fixture job end to end and reports one outcome each, with no network', async () => {
    const lines = [];
    const realFetch = globalThis.fetch;
    globalThis.fetch = () => {
      throw new Error('network used in dry-run');
    };
    try {
      const code = await main(['--dry-run', '--fixture', join(HERE, 'fixtures', 'batch.json')], { PATH: process.env.PATH, HOME: process.env.HOME }, (s) => lines.push(s));
      expect(code).toBe(0);
    } finally {
      globalThis.fetch = realFetch;
    }
    const report = JSON.parse(lines.at(-1));
    expect(report.outcomes.map((o) => o.status)).toEqual(['merged', 'pr_opened', 'could_not_fix']);
    expect(report.outcomes[1].note).toMatch(/^question:/);
    expect(report.usage.length).toBeGreaterThan(0);
  });
  it('I-1: a malformed HANDS_USAGE_THRESHOLD_PCT refuses every job and says why', async () => {
    const lines = [];
    const code = await main(['--dry-run', '--fixture', join(HERE, 'fixtures', 'batch.json')], { PATH: process.env.PATH, HOME: process.env.HOME, HANDS_USAGE_THRESHOLD_PCT: 'eighty' }, (s) => lines.push(s));
    expect(code).toBe(0);
    const report = JSON.parse(lines.at(-1));
    expect(report.outcomes.map((o) => o.status)).toEqual(['skipped_usage', 'skipped_usage', 'skipped_usage']);
    expect(lines.join('\n')).toMatch(/not a number 1\.\.100: refusing every job/);
  });
  it('sweepWorkdir removes only job_* dirs (crash leftovers), never anything else', async () => {
    const d = await mkdtemp(join(tmpdir(), 'hands-sweep-'));
    await mkdir(join(d, 'job_abc', 'work'), { recursive: true });
    await writeFile(join(d, 'keep.txt'), 'x');
    expect(sweepWorkdir(d)).toBe(1);
    expect(existsSync(join(d, 'keep.txt'))).toBe(true);
    expect(existsSync(join(d, 'job_abc'))).toBe(false);
    expect(sweepWorkdir(join(d, 'missing'))).toBe(0);
  });
  it('usage errors exit 64; a real run without brain credentials cannot start (exit 2)', async () => {
    expect(await main(['--dry-run'], {}, () => {})).toBe(64);
    expect(await main(['--run', 'run_x'], { HANDS_CONFIG_JSON: '{"repos":{}}', HANDS_GIT_NAME: 'n', HANDS_GIT_EMAIL: 'e' }, () => {})).toBe(2);
  });
});

describe('example config + Dockerfile', () => {
  it('os/config/hands.example.json is a valid hands config', () => {
    expect(validateConfig(JSON.parse(readFileSync(join(HERE, '..', '..', 'config', 'hands.example.json'), 'utf8')))).toBeNull();
  });
  it('Dockerfile passes the engine-free checks', () => {
    expect(checkDockerfile(readFileSync(join(HERE, 'Dockerfile'), 'utf8'))).toEqual([]);
  });
  it('the checker catches an unpinned base, a baked token, a root user and a missing COPY source', () => {
    const bad = 'FROM node:22 AS b\nFROM node:22\nENV GH_TOKEN=ghp_x\nCOPY nope.txt /x\nUSER root\nENTRYPOINT node x\n';
    const p = checkDockerfile(bad).join('\n');
    for (const re of [/not pinned by digest/, /credential-like/, /non-root required/, /COPY source missing/, /exec form/]) expect(p).toMatch(re);
  });
});

describe('providers', () => {
  it('github-actions is not selectable unless explicitly enabled and configured', () => {
    expect(selectProvider('github-actions', {}).provider).toBeNull();
    expect(selectProvider('github-actions', { HANDS_GITHUB_ACTIONS_ENABLED: 'true' }).reason).toMatch(/disabled .*CI only/);
    expect(selectProvider('github-actions', { HANDS_GITHUB_ACTIONS_ENABLED: 'true', HANDS_GITHUB_ACTIONS_REPO: 'o/r', HANDS_GITHUB_ACTIONS_WORKFLOW: 'h.yml', HANDS_GITHUB_ACTIONS_TOKEN: 't' }).provider.name).toBe('github-actions');
  });
  it('a throwing provider surfaces as a rejected start (the brain records it as a failed run)', async () => {
    const { provider } = selectProvider('cloudflare-sandbox', {});
    await expect(provider.start({ runId: 'r', kind: 'nightly', perJobCapMin: 45 })).rejects.toThrow(/binding missing/);
    await expect(selectProvider('mac-local').provider.start({ runId: 'r', kind: 'nightly', perJobCapMin: 45 })).rejects.toThrow(/pull-only/);
  });
  it('provider files stay Worker-compatible (no node: imports; the brain bundles them)', () => {
    for (const f of ['index.mjs', 'cloudflare-sandbox.mjs', 'mac-local.mjs', 'github-actions.mjs']) expect(readFileSync(join(HERE, 'providers', f), 'utf8')).not.toMatch(/from 'node:/);
  });
});
