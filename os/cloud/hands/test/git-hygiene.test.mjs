// I-3 / S1 with REAL git: hooks and fsmonitor planted in the tree Claude edited (and even in the commit tree) never
// execute, and only the intended file lands on the pushed branch. Origin is a local bare repo (file:// is allowed here
// through the test-only cfg.allowFileRemote; production keeps protocol.file.allow=never).
import { execFileSync } from 'node:child_process';
import { chmod, mkdir, mkdtemp, writeFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { exec as realExec } from '../lib/exec.mjs';
import { runJob } from '../lib/job.mjs';

const gitEnv = { ...process.env, GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null', GIT_AUTHOR_NAME: 't', GIT_AUTHOR_EMAIL: 't@x', GIT_COMMITTER_NAME: 't', GIT_COMMITTER_EMAIL: 't@x' };
const g = (cwd, ...args) => execFileSync('git', args, { cwd, env: gitEnv, encoding: 'utf8' });

async function origin() {
  const root = await mkdtemp(join(tmpdir(), 'hands-git-'));
  const seed = join(root, 'seed');
  await mkdir(join(seed, '.github', 'workflows'), { recursive: true });
  await writeFile(join(seed, 'README.md'), 'old\n');
  await writeFile(join(seed, '.github', 'workflows', 'ci.yml'), 'on: pull_request\n');
  g(seed, 'init', '-q', '-b', 'main');
  g(seed, 'add', '.');
  g(seed, 'commit', '-q', '-m', 'seed');
  await mkdir(join(root, 'o'), { recursive: true });
  g(root, 'clone', '-q', '--bare', seed, join(root, 'o', 'r.git'));
  return root;
}

async function hook(path, marker) {
  await writeFile(path, `#!/bin/sh\necho "$0" >> ${marker}\n`);
  await chmod(path, 0o755);
}

describe('git hygiene with real git', () => {
  it('planted hooks, hooksPath and fsmonitor never execute; only the intended change is pushed', async () => {
    const root = await origin();
    const marker = join(root, 'PWNED');
    const exec = async (cmd, args, opts = {}) => {
      if (cmd === 'git') {
        const r = await realExec(cmd, args, opts);
        // attacker also gets into the commit tree right after it is cloned (cannot happen in the container; belt and braces)
        if (args.includes('clone') && String(args.at(-1)).endsWith('/commit')) {
          await hook(join(args.at(-1), '.git', 'hooks', 'pre-commit'), marker);
          await hook(join(args.at(-1), '.git', 'hooks', 'pre-push'), marker);
          execFileSync('git', ['config', 'core.fsmonitor', join(root, 'fsm.sh')], { cwd: args.at(-1), env: gitEnv });
        }
        return r;
      }
      if (cmd === 'claude') {
        const W = opts.cwd;
        await writeFile(join(W, 'README.md'), 'new\n');
        for (const h of ['pre-commit', 'post-commit', 'pre-push', 'post-checkout', 'reference-transaction']) await hook(join(W, '.git', 'hooks', h), marker);
        await mkdir(join(W, '.git', 'evil-hooks'), { recursive: true });
        await hook(join(W, '.git', 'evil-hooks', 'pre-commit'), marker);
        await hook(join(root, 'fsm.sh'), marker);
        execFileSync('git', ['config', 'core.hooksPath', join(W, '.git', 'evil-hooks')], { cwd: W, env: gitEnv });
        execFileSync('git', ['config', 'core.fsmonitor', join(root, 'fsm.sh')], { cwd: W, env: gitEnv });
        execFileSync('git', ['config', 'credential.helper', `!${join(root, 'fsm.sh')}`], { cwd: W, env: gitEnv });
        opts.onLine?.(JSON.stringify({ type: 'result', is_error: false, result: 'Fixed README.' }));
        return { code: 0, stdout: '', stderr: '', timedOut: false };
      }
      if (cmd === 'gh') return { code: 0, stdout: 'https://github.com/o/r/pull/9\n', stderr: '', timedOut: false };
      return { code: 0, stdout: '', stderr: '', timedOut: false }; // npm ci / npm test / merge gate
    };
    const cfg = {
      workdir: join(root, 'work'),
      jobCapMin: 5,
      claudeModel: 'sonnet',
      maxTurns: 5,
      branchPrefix: 'os/fix-',
      claudeBin: 'claude',
      osHome: '/opt/os',
      gitName: 'hands',
      gitEmail: 'hands@x',
      gitleaks: '',
      gitHost: `file://${root}`,
      allowFileRemote: true,
      repos: { 'o/r': { defaultBranch: 'main', test: ['npm', 'test'], mergeGate: ['bash', 'gate', '{pr}', '{sha}', '--workflows', '{base_workflows}'] } },
    };
    const job = { id: 'job_git1', fingerprint: 'f', lane: 'nightly', mergePolicy: 'auto-when-gate-green', finding: { source: 'w', kind: 'docs', key: 'k', title: 'fix readme', repo: 'o/r' } };
    const out = await runJob(job, { cfg, exec, env: { PATH: process.env.PATH, HOME: root }, creds: {} });
    expect(out).toMatchObject({ status: 'merged' });
    expect(existsSync(marker)).toBe(false);
    const bare = join(root, 'o', 'r.git');
    expect(g(bare, 'show', 'os/fix-job_git1:README.md')).toBe('new\n');
    expect(g(bare, 'diff', '--name-only', 'main', 'os/fix-job_git1').trim()).toBe('README.md');
    expect(g(bare, 'log', '-1', '--format=%an <%ae>', 'os/fix-job_git1').trim()).toBe('hands <hands@x>');
  });
});
