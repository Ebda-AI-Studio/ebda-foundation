// runJob + runBatch with every leaf mocked (git, gh, claude, the repo's commands, the brain). No network.
import { mkdtemp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { recordingBrain } from '../lib/brain-client.mjs';
import { validateConfig } from '../lib/config.mjs';
import { changedPaths, runJob } from '../lib/job.mjs';
import { runBatch } from '../lib/run.mjs';
import { UsageGuard } from '../lib/usage-guard.mjs';

const RESET = Math.floor(Date.now() / 1000) + 86400;
const rl = (u) => JSON.stringify({ type: 'rate_limit_event', rate_limit_info: { status: 'allowed', rateLimitType: 'seven_day', utilization: u, resetsAt: RESET, unifiedWindows: { seven_day: { utilization: u, resetsAt: RESET } } } });

async function cfgWith(repo = {}) {
  return {
    workdir: await mkdtemp(join(tmpdir(), 'hands-job-')),
    jobCapMin: 45,
    runCapMin: 90,
    claudeModel: 'sonnet',
    maxTurns: 10,
    branchPrefix: 'os/fix-',
    claudeBin: 'claude',
    osHome: '/opt/os',
    gitName: 'n',
    gitEmail: 'e@x',
    repos: { 'o/r': { defaultBranch: 'main', install: ['npm', 'ci'], test: ['npm', 'test'], mergeGate: ['bash', '{os_home}/ops/merge-gate.sh', '{pr}', '{sha}', '--repo', '{repo}'], ...repo } },
  };
}

/** Scripted exec. opts: { claude: {result, is_error, timedOut, usage}, status: [first, afterTests], tests: code, gate: code } */
function fakeExec(o = {}) {
  const calls = [];
  let statusCall = 0;
  const ok = (stdout = '') => ({ code: 0, stdout, stderr: '', timedOut: false });
  const exec = async (cmd, args, opts = {}) => {
    calls.push({ cmd, args, env: opts.env });
    if (cmd === 'git') {
      if (args[0] === 'status') return ok((o.status ?? [' M src/a.ts\0', ' M src/a.ts\0?? coverage/x.json\0'])[statusCall++] ?? '');
      if (args[0] === 'rev-parse') return ok('abcdef1234567\n');
      if (args[0] === 'push' && o.push) return { code: 1, stdout: '', stderr: 'denied', timedOut: false };
      return ok();
    }
    if (cmd === 'gh') return ok('https://github.com/o/r/pull/7\n');
    if (cmd === 'claude') {
      const c = o.claude ?? {};
      opts.onLine?.(rl(c.usage ?? 0.3));
      opts.onLine?.(JSON.stringify({ type: 'result', is_error: !!c.is_error, result: c.result ?? 'Fixed it.' }));
      return { code: c.is_error ? 1 : 0, stdout: '', stderr: '', timedOut: !!c.timedOut };
    }
    if (cmd === 'bash') return { code: o.gate ?? 0, stdout: '', stderr: o.gate ? 'REFUSED' : '', timedOut: false };
    if (cmd === 'npm' && args[0] === 'test') return { code: o.tests ?? 0, stdout: o.tests ? '1 failed' : 'ok', stderr: '', timedOut: false };
    return ok();
  };
  return { exec, calls };
}

const job = (kind = 'docs', x = {}) => ({ id: `job_${kind.replace(/\W/g, '')}1`, fingerprint: 'f', lane: 'nightly', mergePolicy: 'auto-when-gate-green', finding: { source: 'w', kind, key: 'k', title: `fix ${kind}`, repo: 'o/r', ...(x.finding ?? {}) }, ...x });
const ENV = { PATH: '/bin', GH_TOKEN: 'gh-secret', HANDS_TOKEN: 'h-secret', CLAUDE_CODE_OAUTH_TOKEN: 'c-secret' };

describe('runJob', () => {
  it('pre-approved class + green gate: merges through the repo gate with the PR number and head sha', async () => {
    const f = fakeExec();
    const o = await runJob(job('docs'), { cfg: await cfgWith(), exec: f.exec, env: ENV });
    expect(o).toMatchObject({ status: 'merged', prUrl: 'https://github.com/o/r/pull/7' });
    expect(f.calls.find((c) => c.cmd === 'bash').args).toEqual(['/opt/os/ops/merge-gate.sh', '7', 'abcdef1234567', '--repo', 'o/r']);
  });
  it('commits explicit paths only (never -A), and only files Claude changed, not test output', async () => {
    const f = fakeExec();
    await runJob(job('docs'), { cfg: await cfgWith(), exec: f.exec, env: ENV });
    const add = f.calls.find((c) => c.cmd === 'git' && c.args[0] === 'add');
    expect(add.args).toEqual(['add', '--', 'src/a.ts']);
    expect(f.calls.some((c) => c.args.includes('-A') || c.args.includes('--no-verify'))).toBe(false);
  });
  it('credentials: Claude never sees GH_TOKEN/HANDS_TOKEN; the repo commands see no credential at all', async () => {
    const f = fakeExec();
    await runJob(job('docs'), { cfg: await cfgWith(), exec: f.exec, env: ENV });
    const claude = f.calls.find((c) => c.cmd === 'claude');
    expect(claude.env.GH_TOKEN).toBeUndefined();
    expect(claude.env.HANDS_TOKEN).toBeUndefined();
    expect(claude.env.CLAUDE_CODE_OAUTH_TOKEN).toBe('c-secret');
    for (const c of f.calls.filter((x) => x.cmd === 'npm')) expect([c.env.GH_TOKEN, c.env.CLAUDE_CODE_OAUTH_TOKEN, c.env.HANDS_TOKEN]).toEqual([undefined, undefined, undefined]);
  });
  it('red gate: PR stays open and the outcome is a question', async () => {
    const o = await runJob(job('lint'), { cfg: await cfgWith(), exec: fakeExec({ gate: 1 }).exec, env: ENV });
    expect(o).toMatchObject({ status: 'pr_opened', note: expect.stringMatching(/^question: merge gate not green/) });
  });
  it('not a pre-approved class: PR + question, the merge gate is never even run', async () => {
    const f = fakeExec();
    const o = await runJob(job('ci-failure', { mergePolicy: 'pr-and-question' }), { cfg: await cfgWith(), exec: f.exec, env: ENV });
    expect(o).toMatchObject({ status: 'pr_opened', note: expect.stringMatching(/^question:/) });
    expect(f.calls.some((c) => c.cmd === 'bash')).toBe(false);
  });
  it('a fix touching a protected path (workflows, env, migrations) is never auto-merged', async () => {
    const f = fakeExec({ status: [' M .github/workflows/ci.yml\0', ' M .github/workflows/ci.yml\0'] });
    const o = await runJob(job('lint'), { cfg: await cfgWith(), exec: f.exec, env: ENV });
    expect(o).toMatchObject({ status: 'pr_opened', note: expect.stringMatching(/touches \.github\/workflows\/ci\.yml/) });
    expect(f.calls.some((c) => c.cmd === 'bash')).toBe(false);
  });
  it('tests fail: could_not_fix, nothing pushed', async () => {
    const f = fakeExec({ tests: 1 });
    const o = await runJob(job('docs'), { cfg: await cfgWith(), exec: f.exec, env: ENV });
    expect(o).toMatchObject({ status: 'could_not_fix', note: expect.stringMatching(/tests failed/) });
    expect(f.calls.some((c) => c.args[0] === 'push')).toBe(false);
  });
  it('claude over the cap: timed_out; claude says it cannot: could_not_fix with its reason; no change: could_not_fix', async () => {
    expect(await runJob(job('docs'), { cfg: await cfgWith(), exec: fakeExec({ claude: { timedOut: true } }).exec, env: ENV })).toMatchObject({ status: 'timed_out' });
    expect(await runJob(job('docs'), { cfg: await cfgWith(), exec: fakeExec({ claude: { result: 'HANDS_CANNOT_FIX: needs a migration' } }).exec, env: ENV })).toMatchObject({ status: 'could_not_fix', note: 'needs a migration' });
    expect(await runJob(job('docs'), { cfg: await cfgWith(), exec: fakeExec({ status: [''] }).exec, env: ENV })).toMatchObject({ status: 'could_not_fix', note: 'claude made no change' });
  });
  it('repo without hands config, or a destructive class without proceed: nothing runs at all', async () => {
    const f = fakeExec();
    expect(await runJob(job('docs', { finding: { repo: 'x/unknown' } }), { cfg: await cfgWith(), exec: f.exec, env: ENV })).toMatchObject({ status: 'could_not_fix', note: expect.stringMatching(/no hands config/) });
    expect(await runJob(job('data-deletion'), { cfg: await cfgWith(), exec: f.exec, env: ENV })).toMatchObject({ status: 'could_not_fix', note: expect.stringMatching(/destructive/) });
    expect(f.calls).toHaveLength(0);
  });
  it('a proceed-answered destructive job may get a PR but is never merged', async () => {
    const f = fakeExec();
    const o = await runJob(job('data-deletion', { answer: 'proceed' }), { cfg: await cfgWith(), exec: f.exec, env: ENV });
    expect(o.status).toBe('pr_opened');
    expect(f.calls.some((c) => c.cmd === 'bash')).toBe(false);
  });
});

describe('runBatch', () => {
  it('sequential; the usage guard stops the run before a job once usage crosses the threshold; the rest go back as skipped_usage', async () => {
    let n = 0;
    const exec = async (cmd, args, opts) => {
      if (cmd === 'claude') n++;
      return fakeExec({ claude: { usage: n === 1 ? 0.85 : 0.3 } }).exec(cmd, args, opts);
    };
    const batch = { runId: 'run_1', kind: 'nightly', perJobCapMin: 45, usageThresholdPct: 80, jobs: [job('docs'), job('lint'), job('test')] };
    const brain = recordingBrain(batch);
    const usage = new UsageGuard({ thresholdPct: 80, probe: async () => [JSON.parse(rl(0.1))] });
    const res = await runBatch(batch, { brain, cfg: await cfgWith(), exec, usage, env: ENV });
    expect(res.map((r) => r.status)).toEqual(['merged', 'skipped_usage', 'skipped_usage']);
    expect(n).toBe(1);
    expect(brain.outcomes).toHaveLength(3);
    expect(brain.usageReports[0]).toMatchObject({ weeklyUsedPct: 85, resetsAt: RESET * 1000 });
  });
  it('refuses every job when usage is unknown (Ruling I-4)', async () => {
    const batch = { runId: 'run_2', kind: 'urgent', perJobCapMin: 30, usageThresholdPct: 80, jobs: [job('docs')] };
    const brain = recordingBrain(batch);
    const f = fakeExec();
    const res = await runBatch(batch, { brain, cfg: await cfgWith(), exec: f.exec, usage: new UsageGuard({ thresholdPct: 80, probe: async () => [] }), env: ENV });
    expect(res).toEqual([expect.objectContaining({ status: 'skipped_usage', note: expect.stringMatching(/usage-unknown/) })]);
    expect(f.calls).toHaveLength(0);
  });
  it('the brain threshold wins when it is stricter', async () => {
    const batch = { runId: 'run_3', kind: 'nightly', perJobCapMin: 45, usageThresholdPct: 50, jobs: [job('docs')] };
    const brain = recordingBrain(batch);
    const res = await runBatch(batch, { brain, cfg: await cfgWith(), exec: fakeExec().exec, usage: new UsageGuard({ thresholdPct: 80, probe: async () => [JSON.parse(rl(0.6))] }), env: ENV });
    expect(res[0].status).toBe('skipped_usage');
  });
  it('a job that throws is could_not_fix and the run continues; past the run cap the rest are requeued', async () => {
    let t = 0;
    const now = () => t;
    const exec = async (cmd, args, opts) => {
      if (cmd === 'git' && args[0] === 'clone' && t === 0) {
        t = 100 * 60_000; // the first job eats past the 90-minute run cap
        throw new Error('disk full');
      }
      return fakeExec().exec(cmd, args, opts);
    };
    const batch = { runId: 'run_4', kind: 'nightly', perJobCapMin: 45, usageThresholdPct: 80, jobs: [job('docs'), job('lint')] };
    const brain = recordingBrain(batch);
    const res = await runBatch(batch, { brain, cfg: await cfgWith(), exec, usage: new UsageGuard({ thresholdPct: 80, probe: async () => [JSON.parse(rl(0.1))] }), now, env: ENV });
    expect(res.map((r) => r.status)).toEqual(['could_not_fix', 'skipped_usage']);
    expect(res[0].note).toMatch(/disk full/);
    expect(res[1].note).toMatch(/run cap 90 min/);
  });
});

describe('helpers', () => {
  it('changedPaths parses porcelain -z including renames', () => {
    expect(changedPaths(' M a.ts\0R  new.ts\0old.ts\0?? b.md\0')).toEqual(['a.ts', 'new.ts', 'old.ts', 'b.md']);
  });
  it('config: repo commands must be argv arrays defined per repo', () => {
    expect(validateConfig({ repos: { 'o/r': { test: 'npm test' } } })).toMatch(/argv array/);
    expect(validateConfig({ repos: { bad: { test: ['x'] } } })).toMatch(/owner\/name/);
    expect(validateConfig({ repos: { 'o/r': { test: ['npm', 'test'] } } })).toBeNull();
  });
});
