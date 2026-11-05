// One job, end to end: fresh shallow checkout -> branch -> Claude Code headless (capped) -> the repo's own tests ->
// commit (explicit paths) -> push -> PR -> merge through the repo's merge gate ONLY when policy.mayAutoMerge says so.
// Every external effect goes through ctx.exec (git, gh, claude, the repo's commands), so tests mock all of it.
// Returns a JobOutcome for the brain: merged | pr_opened | could_not_fix | timed_out.
import { mkdir, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { fill } from './config.mjs';
import { mayAutoMerge, mayWork } from './policy.mjs';
import { buildPrompt, CANNOT_FIX } from './prompt.mjs';

/** Paths a fix must not change on its own; touching one turns auto-merge off (the PR still opens). */
export const PROTECTED = /(^|\/)(\.github\/workflows\/|\.env|wrangler\.(json|jsonc|toml)$|migrations?\/|prisma\/schema|Dockerfile$)/;
/** Credentials Claude and the repo's tests never see: only the hands' own git/gh steps use them. */
const CREDENTIALS = ['GH_TOKEN', 'GITHUB_TOKEN', 'HANDS_TOKEN', 'GH_ENTERPRISE_TOKEN'];

export function scrubbedEnv(env, alsoClaude = false) {
  const e = { ...env };
  for (const k of CREDENTIALS) delete e[k];
  if (alsoClaude) delete e.CLAUDE_CODE_OAUTH_TOKEN;
  return e;
}

/** Parse `git status --porcelain=v1 -z` into changed paths (rename = both paths). */
export function changedPaths(z) {
  const parts = z.split('\0').filter(Boolean);
  const out = [];
  for (let i = 0; i < parts.length; i++) {
    const p = parts[i];
    const xy = p.slice(0, 2);
    out.push(p.slice(3));
    if (xy[0] === 'R' || xy[0] === 'C') out.push(parts[++i]);
  }
  return out.filter(Boolean);
}

export function oneLine(s, n = 300) {
  return String(s ?? '').replace(/\s+/g, ' ').trim().slice(-n);
}

export async function runJob(job, ctx) {
  const { cfg, exec, usage, log = () => {}, now = () => Date.now(), env = process.env } = ctx;
  const slug = job.finding?.repo;
  const repoCfg = slug ? cfg.repos[slug] : undefined;
  if (!slug || !repoCfg) return { status: 'could_not_fix', note: `question: repo ${slug ?? '(none)'} has no hands config; add it to the hands repo config` };
  if (!/^[\w-]{1,64}$/.test(String(job.id))) return { status: 'could_not_fix', note: 'malformed job id' };
  const work = mayWork(job);
  if (!work.ok) return { status: 'could_not_fix', note: `question: ${work.reason}` };

  const capMs = (ctx.capMin ?? cfg.jobCapMin) * 60_000;
  const deadline = Math.min(now() + capMs, ctx.runDeadline ?? Infinity);
  const left = () => Math.max(0, deadline - now());
  const base = repoCfg.defaultBranch ?? 'main';
  const dir = join(cfg.workdir, job.id);
  const branch = `${cfg.branchPrefix}${job.id}`;
  const vars = { dir, repo: slug, base, os_home: cfg.osHome };
  const git = (args, o = {}) => exec('git', args, { cwd: dir, timeoutMs: Math.min(left(), 10 * 60_000), env, ...o });
  const claudeEnv = scrubbedEnv(env);
  const quietEnv = scrubbedEnv(env, true); // the repo's install/test commands see no credential at all

  try {
    await rm(dir, { recursive: true, force: true });
    await mkdir(cfg.workdir, { recursive: true });
    const host = cfg.gitHost ?? 'https://github.com';
    let r = await exec('git', ['clone', '--depth', '1', '--single-branch', '--branch', base, `${host}/${slug}.git`, dir], { cwd: cfg.workdir, timeoutMs: Math.min(left(), 10 * 60_000), env });
    if (r.code !== 0) return { status: 'could_not_fix', note: `clone failed: ${oneLine(r.stderr)}` };
    r = await git(['checkout', '-b', branch]);
    if (r.code !== 0) return { status: 'could_not_fix', note: `branch failed: ${oneLine(r.stderr)}` };

    // Claude Code, headless. Sandboxed (container) runs skip permission prompts; on the Mac only edits + the repo's
    // own test command are allowed.
    const prompt = buildPrompt(job, repoCfg, slug);
    const perm = cfg.sandboxed
      ? ['--permission-mode', 'bypassPermissions']
      : ['--permission-mode', 'acceptEdits', '--allowedTools', ['Read', 'Edit', 'Write', 'Glob', 'Grep', `Bash(${repoCfg.test.join(' ')}:*)`].join(',')];
    let result = null;
    log(`job ${job.id}: claude (${cfg.claudeModel}, cap ${Math.round(left() / 60000)} min)`);
    r = await exec(cfg.claudeBin, ['-p', prompt, '--output-format', 'stream-json', '--verbose', '--model', cfg.claudeModel, '--max-turns', String(cfg.maxTurns), ...perm], {
      cwd: dir,
      env: claudeEnv,
      timeoutMs: left(),
      onLine: (line) => {
        let ev;
        try {
          ev = JSON.parse(line);
        } catch {
          return;
        }
        usage?.observe(ev);
        if (ev.type === 'result') result = ev;
      },
    });
    if (r.timedOut || left() === 0) return { status: 'timed_out', note: `no fix within the ${Math.round(capMs / 60000)}-minute cap` };
    const text = String(result?.result ?? '');
    if (text.includes(CANNOT_FIX)) return { status: 'could_not_fix', note: oneLine(text.slice(text.indexOf(CANNOT_FIX) + CANNOT_FIX.length)) };
    if (r.code !== 0 || result?.is_error) return { status: 'could_not_fix', note: `claude failed: ${oneLine(result?.result ?? r.stderr)}` };

    r = await git(['status', '--porcelain=v1', '-z', '--untracked-files=all']);
    const files = changedPaths(r.stdout);
    if (!files.length) return { status: 'could_not_fix', note: 'claude made no change' };

    // The repo's own affected tests (repo-defined command, never hardcoded here).
    if (repoCfg.install) {
      r = await exec(repoCfg.install[0], fill(repoCfg.install, vars).slice(1), { cwd: dir, env: quietEnv, timeoutMs: left() });
      if (r.timedOut) return { status: 'timed_out', note: 'install hit the cap' };
      if (r.code !== 0) return { status: 'could_not_fix', note: `install failed: ${oneLine(r.stderr || r.stdout)}` };
    }
    r = await exec(repoCfg.test[0], fill(repoCfg.test, vars).slice(1), { cwd: dir, env: quietEnv, timeoutMs: left() });
    if (r.timedOut) return { status: 'timed_out', note: 'tests hit the cap' };
    if (r.code !== 0) return { status: 'could_not_fix', note: `tests failed after the fix: ${oneLine(r.stdout + r.stderr)}` };

    // Re-read: the install/test step must not smuggle extra files into the commit (lockfile churn, build output).
    r = await git(['status', '--porcelain=v1', '-z', '--untracked-files=all']);
    const toAdd = changedPaths(r.stdout).filter((p) => files.includes(p));
    const title = `fix(os): ${String(job.finding.title ?? job.finding.kind).replace(/\s+/g, ' ').slice(0, 80)}`.slice(0, 100);
    const summary = oneLine(text, 1500) || 'Automated fix by the Ebda OS hands.';
    const body = `${summary}\n\nFinding: ${job.finding.kind} ${job.finding.key}${job.finding.url ? `\n${job.finding.url}` : ''}\nJob: ${job.id}`;
    r = await git(['add', '--', ...toAdd]);
    if (r.code !== 0) return { status: 'could_not_fix', note: `git add failed: ${oneLine(r.stderr)}` };
    const ident = ['-c', `user.name=${cfg.gitName}`, '-c', `user.email=${cfg.gitEmail}`];
    r = await git([...ident, 'commit', '-m', title, '-m', body, '-m', `Ebda-OS-Job: ${job.id}`]);
    if (r.code !== 0) return { status: 'could_not_fix', note: `commit failed: ${oneLine(r.stderr || r.stdout)}` };
    const sha = (await git(['rev-parse', 'HEAD'])).stdout.trim();
    r = await git(['push', '-u', 'origin', `HEAD:refs/heads/${branch}`]);
    if (r.code !== 0) return { status: 'could_not_fix', note: `push failed: ${oneLine(r.stderr)}` };
    r = await exec('gh', ['pr', 'create', '--repo', slug, '--base', base, '--head', branch, '--title', title, '--body', body], { cwd: dir, env, timeoutMs: Math.min(left() || 60_000, 5 * 60_000) });
    const prUrl = (r.stdout.match(/https?:\/\/\S+\/pull\/\d+/) ?? [])[0];
    if (r.code !== 0 || !prUrl) return { status: 'could_not_fix', note: `branch ${branch} pushed but PR create failed: ${oneLine(r.stderr)}` };
    const pr = prUrl.split('/').pop();

    // Merge: pre-approved class + no protected path + the repo's merge gate green. Anything else = PR + one question.
    const eligible = mayAutoMerge(job);
    const protectedHit = toAdd.find((p) => PROTECTED.test(p));
    if (!eligible.ok || protectedHit || !repoCfg.mergeGate) {
      const why = !eligible.ok ? eligible.reason : protectedHit ? `the fix touches ${protectedHit}` : 'the repo has no merge gate configured';
      return { status: 'pr_opened', prUrl, note: `question: ${why}; needs your review` };
    }
    const gate = fill(repoCfg.mergeGate, { ...vars, pr, sha });
    log(`job ${job.id}: merge gate ${gate.join(' ')}`);
    r = await exec(gate[0], gate.slice(1), { cwd: dir, env, timeoutMs: Math.max(left(), 60_000) });
    if (r.code === 0) return { status: 'merged', prUrl, note: `pre-approved ${job.finding.kind}; merge gate green` };
    return { status: 'pr_opened', prUrl, note: `question: merge gate not green (exit ${r.code}${r.timedOut ? ', timed out' : ''}): ${oneLine(r.stderr || r.stdout, 200)}` };
  } finally {
    if (!ctx.keepWorkdir) await rm(dir, { recursive: true, force: true }).catch(() => {});
  }
}
