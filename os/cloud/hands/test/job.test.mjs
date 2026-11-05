// runJob + runBatch with every leaf mocked (git, gh, claude, the repo's commands, the brain). No network. The file
// trees are real (temp dirs), so the work-vs-fresh-clone diff, the path allowlists and the commit tree are exercised.
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { recordingBrain } from '../lib/brain-client.mjs';
import { validateConfig } from '../lib/config.mjs';
import { claudePermissionArgs, runJob } from '../lib/job.mjs';
import { runBatch } from '../lib/run.mjs';
import { UsageGuard } from '../lib/usage-guard.mjs';

const RESET = Math.floor(Date.now() / 1000) + 86400;
const rl = (u) => JSON.stringify({ type: 'rate_limit_event', rate_limit_info: { status: 'allowed', rateLimitType: 'seven_day', utilization: u, resetsAt: RESET, unifiedWindows: { seven_day: { utilization: u, resetsAt: RESET } } } });
const PKG = JSON.stringify({ name: 'x', scripts: { test: 'vitest run' }, dependencies: { lodash: '4.17.20' } }, null, 2);
const BASE = { 'README.md': 'old\n', 'src/a.ts': 'export const a = 1\n', 'src/payments/charge.ts': 'charge\n', 'package.json': PKG, 'package-lock.json': '{}\n', 'test/a.test.ts': 't\n', '.github/workflows/ci.yml': 'on: pull_request\n' };

async function cfgWith(repo = {}, extra = {}) {
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
    gitleaks: '',
    repos: { 'o/r': { defaultBranch: 'main', install: ['npm', 'ci'], test: ['npm', 'test'], mergeGate: ['bash', '{os_home}/ops/merge-gate.sh', '{pr}', '{sha}', '--repo', '{repo}', '--workflows', '{base_workflows}'], ...repo } },
    ...extra,
  };
}

async function writeTree(dir, files) {
  for (const [p, c] of Object.entries(files)) {
    await mkdir(dirname(join(dir, p)), { recursive: true });
    await writeFile(join(dir, p), c);
  }
}

const verbOf = (args) => args.filter((a, i) => a !== '-c' && args[i - 1] !== '-c')[0];

/** Scripted leaves. o: { edits: {path: content|null}, claude: {...}, tests, gate, push, dirty, format: {path: content}, gitleaks } */
function fakeExec(o = {}) {
  const calls = [];
  const ok = (stdout = '') => ({ code: 0, stdout, stderr: '', timedOut: false });
  const exec = async (cmd, args, opts = {}) => {
    calls.push({ cmd, args, env: opts.env, cwd: opts.cwd, fd3: opts.fd3 });
    const real = cmd === 'setpriv' ? args[args.indexOf('--') + 1] : cmd;
    const rargs = cmd === 'setpriv' ? args.slice(args.indexOf('--') + 2) : args;
    if (real === 'git') {
      const v = verbOf(rargs);
      if (v === 'clone') {
        await writeTree(rargs.at(-1), { ...BASE, ...(o.base ?? {}) });
        return ok();
      }
      if (v === 'rev-parse') return ok('abcdef1234567\n');
      if (v === 'check-ignore') return { code: 1, stdout: '', stderr: '', timedOut: false };
      if (v === 'status') return ok(o.dirty ? ' M x\0' : '');
      if (v === 'push' && o.push) return { code: 1, stdout: '', stderr: 'denied', timedOut: false };
      return ok();
    }
    if (real === 'gh') return ok('https://github.com/o/r/pull/7\n');
    if (real === 'claude') {
      const c = o.claude ?? {};
      if (!c.timedOut) {
        for (const [p, v] of Object.entries(o.edits ?? { 'README.md': 'new\n' })) {
          if (v === null) await rm(join(opts.cwd, p), { force: true });
          else await writeTree(opts.cwd, { [p]: v });
        }
      }
      opts.onLine?.(rl(c.usage ?? 0.3));
      opts.onLine?.(JSON.stringify({ type: 'result', is_error: !!c.is_error, result: c.result ?? 'Fixed it.' }));
      return { code: c.is_error ? 1 : 0, stdout: '', stderr: '', timedOut: !!c.timedOut };
    }
    if (real === 'prettier') {
      for (const [p, v] of Object.entries(o.format ?? {})) await writeFile(join(opts.cwd, p), v);
      return ok();
    }
    if (real === 'bash') return { code: o.gate ?? 0, stdout: '', stderr: o.gate ? 'REFUSED' : '', timedOut: false };
    if (real === 'gitleaks') return { code: o.gitleaks ?? 0, stdout: '', stderr: '', timedOut: false };
    if (real === 'npm' && rargs[0] === 'test') return { code: o.tests ?? 0, stdout: o.tests ? '1 failed' : 'ok', stderr: '', timedOut: false };
    return ok();
  };
  return { exec, calls };
}

const job = (kind = 'docs', x = {}) => ({ id: `job_${kind.replace(/\W/g, '')}1`, fingerprint: 'f', lane: 'nightly', mergePolicy: 'auto-when-gate-green', finding: { source: 'w', kind, key: 'k', title: `fix ${kind}`, repo: 'o/r', ...(x.finding ?? {}) }, ...x });
const ENV = { PATH: '/bin', HOME: '/home/u' };
const CREDS = { ghToken: 'gh-secret', claudeToken: 'c-secret' };
const run = async (j, o = {}, cfgExtra = {}, repo = {}) => {
  const f = fakeExec(o);
  const out = await runJob(j, { cfg: await cfgWith(repo, cfgExtra), exec: f.exec, env: ENV, creds: CREDS });
  return { out, calls: f.calls };
};

describe('runJob: merge path', () => {
  it('pre-approved docs change + green gate: merges; the gate reads the pristine base workflows, never the work tree', async () => {
    const { out, calls } = await run(job('docs'));
    expect(out).toMatchObject({ status: 'merged', prUrl: 'https://github.com/o/r/pull/7' });
    const gate = calls.find((c) => c.cmd === 'bash');
    expect(gate.args.slice(0, 5)).toEqual(['/opt/os/ops/merge-gate.sh', '7', 'abcdef1234567', '--repo', 'o/r']);
    expect(gate.args.at(-1)).toMatch(/job_docs1\/base-workflows$/);
    expect(gate.cwd).toMatch(/job_docs1\/private$/);
  });
  it('commits explicit paths from the FRESH clone; no git call runs in the work tree after Claude', async () => {
    const { calls } = await run(job('docs'));
    const ci = calls.findIndex((c) => c.cmd === 'claude');
    const add = calls.find((c) => c.cmd === 'git' && verbOf(c.args) === 'add');
    expect(add.args.slice(add.args.indexOf('add'))).toEqual(['add', '--', 'README.md']);
    expect(add.cwd).toMatch(/\/commit$/);
    expect(calls.slice(ci + 1).filter((c) => c.cmd === 'git' && c.cwd?.endsWith('/work'))).toEqual([]);
    for (const c of calls.filter((x) => x.cmd === 'git')) {
      expect(c.args).toEqual(expect.arrayContaining(['core.hooksPath=/dev/null', 'core.fsmonitor=false', 'protocol.file.allow=never']));
      expect(c.env.GIT_CONFIG_NOSYSTEM).toBe('1');
      expect(c.args).not.toContain('--no-verify');
      expect(c.args).not.toContain('-A');
    }
  });
  it('credentials: Claude gets its token on fd 3 only; repo commands get none; GH token only on clone/push (askpass) and gh/gate', async () => {
    const { calls } = await run(job('docs'));
    const claude = calls.find((c) => c.cmd === 'claude');
    expect(claude.fd3).toBe('c-secret');
    expect(JSON.stringify(claude.env)).not.toMatch(/gh-secret|c-secret/);
    expect(claude.env.CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR).toBe('3');
    for (const c of calls.filter((x) => x.cmd === 'npm')) expect(JSON.stringify(c.env)).not.toMatch(/gh-secret|c-secret/);
    const withTok = calls.filter((c) => JSON.stringify(c.env ?? {}).includes('gh-secret')).map((c) => (c.cmd === 'git' ? `git ${verbOf(c.args)}` : c.cmd));
    expect(new Set(withTok)).toEqual(new Set(['git clone', 'git push', 'gh', 'bash']));
    const push = calls.find((c) => c.cmd === 'git' && verbOf(c.args) === 'push');
    expect(push.env.GIT_ASKPASS).toMatch(/askpass\.sh$/);
    expect(push.args.join(' ')).not.toContain('gh-secret');
  });
  it('container: untrusted commands run as the sandbox user via setpriv and the work tree is chowned to it', async () => {
    const { calls } = await run(job('docs'), {}, { sandboxUser: 'node', sandboxHome: '/home/node', sandboxed: true });
    expect(calls.find((c) => c.cmd === 'chown').args).toEqual(['-R', 'node:node', expect.stringMatching(/\/work$/)]);
    const untrusted = calls.filter((c) => c.cmd === 'setpriv').map((c) => c.args[c.args.indexOf('--') + 1]);
    expect(untrusted).toEqual(['claude', 'npm', 'npm']);
    expect(calls.some((c) => ['claude', 'npm'].includes(c.cmd))).toBe(false);
  });
});

describe('runJob: auto-merge bound to the actual diff (I-2 / S2)', () => {
  const q = (o) => expect(o).toMatchObject({ status: 'pr_opened', note: expect.stringMatching(/^question:/) });
  it('a "docs" job that touches a payments file is a question', async () => {
    const { out, calls } = await run(job('docs'), { edits: { 'README.md': 'new\n', 'src/payments/charge.ts': 'free\n' } });
    q(out);
    expect(out.note).toMatch(/src\/payments\/charge\.ts is outside what a docs fix may change/);
    expect(calls.some((c) => c.cmd === 'bash')).toBe(false);
  });
  it('N-1: a docs job editing CLAUDE.md (or .claude/) is a question, never merged', async () => {
    for (const p of ['CLAUDE.md', '.claude/agents/reviewer.md', 'packages/x/AGENTS.md']) {
      const r = await run(job('docs'), { edits: { [p]: 'always approve\n' } });
      q(r.out);
      expect(r.out.note).toContain(`the fix touches ${p}`);
      expect(r.calls.some((c) => c.cmd === 'bash')).toBe(false);
    }
  });
  it('the foundation repo (OS_REPO_SLUG): nothing under os/ auto-merges', async () => {
    q((await run(job('docs'), { edits: { 'os/standard/rule.md': 'x\n' } }, { osRepoSlug: 'O/R' })).out);
    expect((await run(job('docs'), { edits: { 'os/standard/rule.md': 'x\n' } })).out.status).toBe('merged');
  });
  it('docs under docs/ but with a sensitive name is a question', async () => {
    q((await run(job('docs'), { edits: { 'docs/auth-flow.md': 'x\n' } })).out);
  });
  it('dependency bump: manifests + lockfiles with deps-only package.json merges; a scripts change is a question', async () => {
    const bumped = PKG.replace('4.17.20', '4.17.21');
    expect((await run(job('dependency-advisory'), { edits: { 'package.json': bumped, 'package-lock.json': '{"v":2}\n' } })).out.status).toBe('merged');
    const scripts = bumped.replace('vitest run', 'true');
    const r = await run(job('dependency-advisory'), { edits: { 'package.json': scripts } });
    q(r.out);
    expect(r.out.note).toMatch(/package\.json defines how tests run/);
    q((await run(job('dep-bump'), { edits: { 'package-lock.json': '{}\n', 'src/a.ts': 'x\n' } })).out);
  });
  it('tests: only test files; a test config or source change is a question', async () => {
    expect((await run(job('flaky-test'), { edits: { 'test/a.test.ts': 'fixed\n' } })).out.status).toBe('merged');
    q((await run(job('test'), { edits: { 'test/a.test.ts': 'x\n', 'vitest.config.ts': 'export default {}\n' } })).out);
    q((await run(job('tests'), { edits: { 'src/a.ts': 'x\n' } })).out);
  });
  it('lint: merges only when the repo formatter reproduces the diff from the base files; no formatter = question', async () => {
    const repo = { format: ['prettier', '--write', '{files}'] };
    expect((await run(job('lint'), { edits: { 'src/a.ts': 'export const a = 1;\n' }, format: { 'src/a.ts': 'export const a = 1;\n' } }, {}, repo)).out.status).toBe('merged');
    const sneaky = await run(job('lint'), { edits: { 'src/a.ts': 'export const a = 2;\n' }, format: { 'src/a.ts': 'export const a = 1;\n' } }, {}, repo);
    q(sneaky.out);
    expect(sneaky.out.note).toMatch(/differs from what the formatter produces/);
    const noFmt = await run(job('lint'), { edits: { 'src/a.ts': 'export const a = 1;\n' } });
    expect(noFmt.out.note).toMatch(/no format command/);
  });
  it('protected paths (workflows) are never auto-merged, even in a pre-approved class', async () => {
    q((await run(job('lint'), { edits: { '.github/workflows/ci.yml': 'on: push\n' }, format: {} }, {}, { format: ['prettier', '{files}'] })).out);
  });
  it('red gate: question; non-pre-approved class: question without running the gate', async () => {
    expect((await run(job('docs'), { gate: 1 })).out.note).toMatch(/^question: merge gate not green/);
    const r = await run(job('ci-failure', { mergePolicy: 'pr-and-question' }));
    q(r.out);
    expect(r.calls.some((c) => c.cmd === 'bash')).toBe(false);
  });
  it('S3: refuses when the commit tree shows changes beyond the committed diff', async () => {
    const r = await run(job('docs'), { dirty: true });
    expect(r.out).toMatchObject({ status: 'could_not_fix', note: expect.stringMatching(/beyond the committed diff/) });
    expect(r.calls.some((c) => c.cmd === 'git' && verbOf(c.args) === 'push')).toBe(false);
  });
});

describe('tree reads never follow symlinks (N-2)', () => {
  it('a file swapped for a symlink between the walk and the read is refused, not read through', async () => {
    const { treeDiff } = await import('../lib/tree.mjs');
    const { symlink } = await import('node:fs/promises');
    const root = await mkdtemp(join(tmpdir(), 'hands-swap-'));
    const W = join(root, 'w');
    const C = join(root, 'c');
    const secret = join(root, 'secret.txt');
    await writeFile(secret, 'TOP SECRET\n');
    await writeTree(W, { 'a.md': 'new\n', 'docs/b.md': 'b\n' });
    await writeTree(C, { 'a.md': 'old\n', 'docs/b.md': 'b\n' });
    const r = await treeDiff(W, C, { beforeRead: async (p) => { if (p === 'a.md') { await rm(join(W, 'a.md')); await symlink(secret, join(W, 'a.md')); } } });
    expect(r.refused).toMatch(/a\.md: refused to read/);
    expect(JSON.stringify(r)).not.toContain('TOP SECRET');
    // a parent dir swapped for a link is refused too
    await writeTree(W, { 'docs/b.md': 'changed\n' });
    await rm(join(W, 'a.md'));
    await writeFile(join(W, 'a.md'), 'new\n');
    const outside = join(root, 'outside');
    await writeTree(outside, { 'b.md': 'TOP SECRET\n' });
    const r2 = await treeDiff(W, C, { beforeRead: async (p) => { if (p === 'docs/b.md') { await rm(join(W, 'docs'), { recursive: true }); await symlink(outside, join(W, 'docs')); } } });
    expect(r2.refused).toBeTruthy();
    expect(JSON.stringify(r2)).not.toContain('TOP SECRET');
  });
});

describe('runJob: refusals', () => {
  it('secret scan: a token in the diff or the PR text blocks the push', async () => {
    const tok = `ghp_${'R8x2Lq9ZpV4mK7tY1wN3bC6dF0gH5jS2aE8u'}`;
    const r = await run(job('docs'), { edits: { 'README.md': `key ${tok}\n` } });
    expect(r.out).toMatchObject({ status: 'could_not_fix', note: expect.stringMatching(/secret scan hit \(GitHub token in README\.md\)/) });
    expect(r.out.note).not.toContain(tok);
    expect(r.calls.some((c) => c.cmd === 'git' && verbOf(c.args) === 'push')).toBe(false);
    const body = await run(job('docs'), { claude: { result: `done, used ${tok}` } });
    expect(body.out.note).toMatch(/secret scan hit/);
    const gl = await run(job('docs'), { gitleaks: 7 }, { gitleaks: 'gitleaks' });
    expect(gl.out.note).toMatch(/gitleaks found a secret/);
  });
  it('symlinks in the diff are refused (never copied into the commit tree)', async () => {
    const f = fakeExec();
    const base = f.exec;
    const exec = async (cmd, args, opts) => {
      const r = await base(cmd, args, opts);
      if (cmd === 'claude') await import('node:fs/promises').then((fs) => fs.symlink('/etc/passwd', join(opts.cwd, 'leak.md')));
      return r;
    };
    const out = await runJob(job('docs'), { cfg: await cfgWith(), exec, env: ENV, creds: CREDS });
    expect(out).toMatchObject({ status: 'could_not_fix', note: expect.stringMatching(/leak\.md is a symlink/) });
  });
  it('tests fail: could_not_fix, nothing pushed; claude timeout / cannot / no change', async () => {
    const t = await run(job('docs'), { tests: 1 });
    expect(t.out).toMatchObject({ status: 'could_not_fix', note: expect.stringMatching(/tests failed/) });
    expect(t.calls.some((c) => verbOf(c.args ?? []) === 'push')).toBe(false);
    expect((await run(job('docs'), { claude: { timedOut: true } })).out.status).toBe('timed_out');
    expect((await run(job('docs'), { claude: { result: 'HANDS_CANNOT_FIX: needs a migration' } })).out).toMatchObject({ status: 'could_not_fix', note: 'needs a migration' });
    expect((await run(job('docs'), { edits: {} })).out).toMatchObject({ status: 'could_not_fix', note: 'claude made no change' });
  });
  it('repo without hands config, or a destructive class without proceed: nothing runs at all', async () => {
    const f = fakeExec();
    expect(await runJob(job('docs', { finding: { repo: 'x/unknown' } }), { cfg: await cfgWith(), exec: f.exec, env: ENV })).toMatchObject({ note: expect.stringMatching(/no hands config/) });
    expect(await runJob(job('data-deletion'), { cfg: await cfgWith(), exec: f.exec, env: ENV })).toMatchObject({ note: expect.stringMatching(/destructive/) });
    expect(f.calls).toHaveLength(0);
  });
  it('a proceed-answered destructive job may get a PR but is never merged', async () => {
    const r = await run(job('data-deletion', { answer: 'proceed' }));
    expect(r.out.status).toBe('pr_opened');
    expect(r.calls.some((c) => c.cmd === 'bash')).toBe(false);
  });
  it('the job dir is removed afterwards', async () => {
    const cfg = await cfgWith();
    await runJob(job('docs'), { cfg, exec: fakeExec().exec, env: ENV, creds: CREDS });
    await expect(readFile(join(cfg.workdir, 'job_docs1', 'work', 'README.md'))).rejects.toThrow();
  });
});

describe('Claude permissions (S4)', () => {
  it('Mac: tools scoped to the checkout, test-defining files and .git/.github denied; package.json editable only for dep bumps', async () => {
    const cfg = await cfgWith();
    const a = claudePermissionArgs(cfg, cfg.repos['o/r'], 'docs');
    const allow = a[a.indexOf('--allowedTools') + 1];
    const deny = a[a.indexOf('--disallowedTools') + 1];
    expect(allow).toContain('Edit(./**)');
    expect(allow).not.toMatch(/(^|,)(Edit|Write|Read)(,|$)/);
    for (const d of ['Edit(./.git/**)', 'Write(./.github/**)', 'Edit(./**/package.json)', 'Edit(./**/vitest.config.*)']) expect(deny).toContain(d);
    expect(claudePermissionArgs(cfg, cfg.repos['o/r'], 'dep-bump').join(' ')).not.toContain('package.json');
    const c = claudePermissionArgs({ ...cfg, sandboxed: true }, cfg.repos['o/r'], 'docs');
    expect(c.slice(0, 3)).toEqual(['--permission-mode', 'bypassPermissions', '--disallowedTools']);
  });
});

describe('runBatch', () => {
  it('sequential; the usage guard stops the run once usage crosses the threshold; the rest go back as skipped_usage', async () => {
    let n = 0;
    const exec = async (cmd, args, opts) => {
      if (cmd === 'claude') n++;
      return fakeExec({ claude: { usage: n === 1 ? 0.85 : 0.3 } }).exec(cmd, args, opts);
    };
    const batch = { runId: 'run_1', kind: 'nightly', perJobCapMin: 45, usageThresholdPct: 80, jobs: [job('docs'), job('lint'), job('test')] };
    const brain = recordingBrain(batch);
    const usage = new UsageGuard({ thresholdPct: 80, probe: async () => [JSON.parse(rl(0.1))] });
    const res = await runBatch(batch, { brain, cfg: await cfgWith(), exec, usage, env: ENV, creds: CREDS });
    expect(res.map((r) => r.status)).toEqual(['merged', 'skipped_usage', 'skipped_usage']);
    expect(n).toBe(1);
    expect(brain.usageReports[0]).toMatchObject({ weeklyUsedPct: 85, resetsAt: RESET * 1000 });
  });
  it('refuses every job when usage is unknown (Ruling I-4)', async () => {
    const batch = { runId: 'run_2', kind: 'urgent', perJobCapMin: 30, usageThresholdPct: 80, jobs: [job('docs')] };
    const f = fakeExec();
    const res = await runBatch(batch, { brain: recordingBrain(batch), cfg: await cfgWith(), exec: f.exec, usage: new UsageGuard({ thresholdPct: 80, probe: async () => [] }), env: ENV });
    expect(res).toEqual([expect.objectContaining({ status: 'skipped_usage', note: expect.stringMatching(/usage-unknown/) })]);
    expect(f.calls).toHaveLength(0);
  });
  it('I-1: a NaN / malformed threshold on either side refuses every job (fail closed)', async () => {
    for (const [mine, brains] of [[Number.NaN, 80], [80, Number.NaN], [80, '80'], [0, 80], [150, 80]]) {
      const batch = { runId: 'run_t', kind: 'nightly', perJobCapMin: 45, usageThresholdPct: brains, jobs: [job('docs')] };
      const f = fakeExec();
      const res = await runBatch(batch, { brain: recordingBrain(batch), cfg: await cfgWith(), exec: f.exec, usage: new UsageGuard({ thresholdPct: mine, probe: async () => [JSON.parse(rl(0.1))] }), env: ENV });
      expect(res[0]).toMatchObject({ status: 'skipped_usage', note: expect.stringMatching(/invalid usage threshold/) });
      expect(f.calls).toHaveLength(0);
    }
  });
  it('the brain threshold wins when it is stricter', async () => {
    const batch = { runId: 'run_3', kind: 'nightly', perJobCapMin: 45, usageThresholdPct: 50, jobs: [job('docs')] };
    const res = await runBatch(batch, { brain: recordingBrain(batch), cfg: await cfgWith(), exec: fakeExec().exec, usage: new UsageGuard({ thresholdPct: 80, probe: async () => [JSON.parse(rl(0.6))] }), env: ENV });
    expect(res[0].status).toBe('skipped_usage');
  });
  it('a job that throws is could_not_fix and the run continues; past the run cap the rest are requeued', async () => {
    let t = 0;
    const exec = async (cmd, args, opts) => {
      if (cmd === 'git' && verbOf(args) === 'clone' && t === 0) {
        t = 100 * 60_000;
        throw new Error('disk full');
      }
      return fakeExec().exec(cmd, args, opts);
    };
    const batch = { runId: 'run_4', kind: 'nightly', perJobCapMin: 45, usageThresholdPct: 80, jobs: [job('docs'), job('lint')] };
    const res = await runBatch(batch, { brain: recordingBrain(batch), cfg: await cfgWith(), exec, usage: new UsageGuard({ thresholdPct: 80, probe: async () => [JSON.parse(rl(0.1))] }), now: () => t, env: ENV });
    expect(res.map((r) => r.status)).toEqual(['could_not_fix', 'skipped_usage']);
    expect(res[0].note).toMatch(/disk full/);
    expect(res[1].note).toMatch(/run cap 90 min/);
  });
});

describe('config', () => {
  it('repo commands must be argv arrays; mergeGate may not read the edited tree; threshold 1..100', () => {
    expect(validateConfig({ repos: { 'o/r': { test: 'npm test' } } })).toMatch(/argv array/);
    expect(validateConfig({ repos: { bad: { test: ['x'] } } })).toMatch(/owner\/name/);
    expect(validateConfig({ repos: { 'o/r': { test: ['t'], mergeGate: ['g', '--workflows', '{dir}/.github/workflows'] } } })).toMatch(/must not read the edited tree/);
    expect(validateConfig({ repos: {}, usageThresholdPct: 101 })).toMatch(/1\.\.100/);
    expect(validateConfig({ repos: { 'o/r': { test: ['npm', 'test'], format: ['prettier', '{files}'] } } })).toBeNull();
  });
});
