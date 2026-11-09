// One job, end to end. Two trees per job:
//   work/   cloned BEFORE Claude runs (base sha recorded then); Claude and the repo's own commands run here, as the
//           sandbox user in the container, with no credential in their env. Hands git never runs here afterwards.
//   commit/ a FRESH clone of the same base sha made AFTER Claude; the changed regular files are copied in (found by a
//           byte comparison, tree.mjs) and this is the only tree git commits and pushes from.
// base-workflows/ is copied from commit/ before the diff is applied: the merge gate derives the required checks from
// it, never from the edited tree (security S3). Auto-merge is decided on the ACTUAL changed paths (diffcheck.mjs).
// Every external effect goes through ctx.exec, so tests mock all of it.
// Returns a JobOutcome: merged | pr_opened | could_not_fix | timed_out.
import { chmod, cp, mkdir, readFile, rm, stat, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { fill } from './config.mjs';
import { diffAllowsAutoMerge, FORMAT_KINDS, PROTECTED, protectedFor, scanSecrets } from './diffcheck.mjs';
import { asSandbox, cloneUrl, gitEnv, prepareJobSecrets, SAFE_GIT, untrustedEnv } from './git.mjs';
import { mayAutoMerge, mayWork } from './policy.mjs';
import { buildPrompt, CANNOT_FIX } from './prompt.mjs';
import { applyChanges, treeDiff } from './tree.mjs';

export { PROTECTED } from './diffcheck.mjs';

const DEP_KINDS = new Set(['dep-bump', 'dependency-advisory', 'cve-bump', 'lockfile-drift']);

export function oneLine(s, n = 300) {
  return String(s ?? '').replace(/\s+/g, ' ').trim().slice(-n);
}

/** Claude permission flags. Edits are scoped to the checkout; CI, env, .git and test-defining files are denied (the diff
 *  check enforces the same rule independently: a denied path in the diff = no auto-merge). */
export function claudePermissionArgs(cfg, repoCfg, kind) {
  const deny = ['.git/**', '.github/**', '.env*', '**/.env*', '**/vitest.config.*', '**/jest.config.*', '**/playwright.config.*', '**/CLAUDE.md', '**/AGENTS.md', '**/GEMINI.md', '.claude/**', '.agents/**', '.cursor/**', '.husky/**', ...(repoCfg.protectedPaths ?? [])];
  if (!DEP_KINDS.has(kind)) deny.push('**/package.json');
  const denyRules = deny.flatMap((p) => [`Edit(./${p})`, `Write(./${p})`]);
  if (cfg.sandboxed) return ['--permission-mode', 'bypassPermissions', '--disallowedTools', denyRules.join(',')];
  const allow = ['Read(./**)', 'Edit(./**)', 'Write(./**)', 'Glob', 'Grep', `Bash(${repoCfg.test.join(' ')}:*)`];
  return ['--permission-mode', 'acceptEdits', '--allowedTools', allow.join(','), '--disallowedTools', [...denyRules, 'WebFetch', 'WebSearch'].join(',')];
}

async function exists(p) {
  try {
    await stat(p);
    return true;
  } catch {
    return false;
  }
}

export async function runJob(job, ctx) {
  const { cfg, exec, usage, log = () => {}, now = () => Date.now(), env = process.env, creds = {} } = ctx;
  const slug = job.finding?.repo;
  const repoCfg = slug ? cfg.repos[slug] : undefined;
  if (!slug || !repoCfg) return { status: 'could_not_fix', note: `question: repo ${slug ?? '(none)'} has no hands config; add it to the hands repo config` };
  if (!/^[\w-]{1,64}$/.test(String(job.id))) return { status: 'could_not_fix', note: 'malformed job id' };
  const work = mayWork(job);
  if (!work.ok) return { status: 'could_not_fix', note: `question: ${work.reason}` };

  const kind = String(job.finding.kind ?? '').toLowerCase();
  // Ruling F-I5: a `pr-stuck` job works ON the stuck PR's own same-repo head branch (never a fork, never the default branch) and
  // pushes to it; it never merges anything. Conflicts are resolved by merging the base into the head (a merge commit).
  const prMode = kind === 'pr-stuck';
  const prHead = prMode ? String(job.finding.detail?.head ?? '') : '';
  const prState = prMode ? String(job.finding.detail?.state ?? '') : '';
  if (prMode && (!/^[\w][\w./-]{0,200}$/.test(prHead) || prHead.includes('..') || prHead.endsWith('.lock') || ['main', 'master', 'production', 'preview', repoCfg.defaultBranch].includes(prHead) || !['conflicting', 'failed-checks'].includes(prState))) {
    return { status: 'could_not_fix', note: `question: pr-stuck job has no usable same-repo head branch (${prHead || 'none'}, ${prState || 'no state'}); nothing touched` };
  }
  const capMs = (ctx.capMin ?? cfg.jobCapMin) * 60_000;
  const deadline = Math.min(now() + capMs, ctx.runDeadline ?? Infinity);
  const left = () => Math.max(0, deadline - now());
  const step = (max = 10 * 60_000) => Math.min(left(), max);
  const base = repoCfg.defaultBranch ?? 'main';
  const jobDir = join(cfg.workdir, job.id);
  const W = join(jobDir, 'work');
  const C = join(jobDir, 'commit');
  const BW = join(jobDir, 'base-workflows');
  const T = join(jobDir, 'private');
  const branch = `${cfg.branchPrefix}${job.id}`;
  const safe = cfg.allowFileRemote ? SAFE_GIT.map((a) => (a === 'protocol.file.allow=never' ? 'protocol.file.allow=always' : a)) : SAFE_GIT;
  const sandboxHome = cfg.sandboxHome ?? env.HOME;
  // role 'claude' = Claude Code and the dependency install; role 'tests' = the repo's test / format commands (another uid, F-I8)
  const testHome = cfg.testUser ? `/home/${cfg.testUser}` : sandboxHome;
  const runUntrusted = (cmd, args, o = {}) => {
    const role = o.role ?? 'claude';
    const [c, a] = asSandbox(cfg, cmd, args, role);
    return exec(c, a, { cwd: W, ...o, env: untrustedEnv(env, { HOME: role === 'tests' ? testHome : sandboxHome, ...(cfg.proxyEnv ?? {}), ...(o.extraEnv ?? {}) }) });
  };
  const chownTo = (user) => (cfg.sandboxUser && user ? exec('chown', ['-R', `${user}:${user}`, W], { timeoutMs: step(60_000) }) : null);

  try {
    await rm(jobDir, { recursive: true, force: true });
    await mkdir(jobDir, { recursive: true, mode: 0o755 });
    const secrets = await prepareJobSecrets(T);
    const git = (cwd, args, o = {}) => exec('git', [...safe, ...args], { cwd, timeoutMs: step(), env: gitEnv(env, secrets, { token: creds.ghToken, auth: o.auth }) });
    const url = cloneUrl(cfg.gitHost ?? 'https://github.com', slug, creds.ghToken);

    // 1. work tree + base sha, before Claude touches anything
    const cloneBranch = prMode ? prHead : base;
    const depth = prMode ? [] : ['--depth', '1'];
    // PR mode, conflicting: merge the base into the head WITHOUT committing, so Claude resolves the markers (same in the commit tree)
    const prPrepare = async (dir) => {
      if (!prMode || prState !== 'conflicting') return null;
      let m = await git(dir, ['fetch', 'origin', `+refs/heads/${base}:refs/remotes/origin/${base}`], { auth: true });
      if (m.code !== 0) return `fetch of ${base} failed: ${oneLine(m.stderr)}`;
      m = await git(dir, ['-c', `user.name=${cfg.gitName}`, '-c', `user.email=${cfg.gitEmail}`, 'merge', '--no-commit', '--no-ff', `origin/${base}`]);
      return m.code === 0 || m.code === 1 ? null : `merge of ${base} failed: ${oneLine(m.stderr || m.stdout)}`;
    };
    let r = await git(jobDir, ['clone', ...depth, '--single-branch', '--branch', cloneBranch, url, W], { auth: true });
    if (r.code !== 0) return { status: 'could_not_fix', note: `clone failed: ${oneLine(r.stderr)}` };
    r = await git(W, ['rev-parse', 'HEAD']);
    const baseSha = r.stdout.trim();
    if (r.code !== 0 || !/^[0-9a-f]{7,64}$/.test(baseSha)) return { status: 'could_not_fix', note: 'could not read the base commit' };
    const prepW = await prPrepare(W);
    if (prepW) return { status: 'could_not_fix', note: prepW };
    if (cfg.sandboxUser) await exec('chown', ['-R', `${cfg.sandboxUser}:${cfg.sandboxUser}`, W], { timeoutMs: step(60_000) });

    // 2. Claude Code, headless, capped; token through fd 3 (not the env); no GitHub credential at all
    const prompt = buildPrompt(job, repoCfg, slug);
    let result = null;
    log(`job ${job.id}: claude (${cfg.claudeModel}, cap ${Math.round(left() / 60000)} min)`);
    r = await runUntrusted(cfg.claudeBin, ['-p', prompt, '--output-format', 'stream-json', '--verbose', '--model', cfg.claudeModel, '--max-turns', String(cfg.maxTurns), ...claudePermissionArgs(cfg, repoCfg, kind)], {
      timeoutMs: left(),
      ...(creds.claudeToken ? { fd3: creds.claudeToken } : {}),
      extraEnv: { CLAUDE_CODE_SUBPROCESS_ENV_SCRUB: '1', DISABLE_AUTOUPDATER: '1', ...(creds.claudeToken ? { CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR: '3' } : {}) },
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

    // 3. fresh commit tree at the same base sha; pristine base workflows for the merge gate
    r = await git(jobDir, ['clone', ...depth, '--single-branch', '--branch', cloneBranch, url, C], { auth: true });
    if (r.code !== 0) return { status: 'could_not_fix', note: `commit clone failed: ${oneLine(r.stderr)}` };
    if ((await git(C, ['rev-parse', 'HEAD'])).stdout.trim() !== baseSha) {
      // PR mode never detaches: the PR branch moved while Claude worked, so the fix would not be a fast-forward
      if (prMode) return { status: 'could_not_fix', note: `PR branch ${prHead} moved while the fix was being made; try again next run` };
      r = await git(C, ['fetch', '--depth', '1', 'origin', baseSha], { auth: true });
      if (r.code !== 0 || (await git(C, ['checkout', '--detach', baseSha])).code !== 0) return { status: 'could_not_fix', note: 'base branch moved and the base commit could not be fetched' };
    }
    if (await exists(join(C, '.github', 'workflows'))) await cp(join(C, '.github', 'workflows'), BW, { recursive: true, verbatimSymlinks: true });
    const prepC = await prPrepare(C);
    if (prepC) return { status: 'could_not_fix', note: prepC };
    if (!prMode) {
      r = await git(C, ['checkout', '-b', branch]);
      if (r.code !== 0) return { status: 'could_not_fix', note: `branch failed: ${oneLine(r.stderr)}` };
    }

    // 4. what Claude changed: byte comparison, never git in the edited tree; ignored files dropped by the clean tree's rules
    const diff = await treeDiff(W, C);
    if (diff.refused) return { status: 'could_not_fix', note: `question: ${diff.refused}` };
    let changes = diff.changes;
    if (changes.length > 2000) return { status: 'could_not_fix', note: `question: ${changes.length} changed files is not a targeted fix` };
    if (changes.length) {
      r = await git(C, ['check-ignore', '-z', '--', ...changes.map((c) => c.path)]);
      const ignored = new Set(r.stdout.split('\0').filter(Boolean));
      changes = changes.filter((c) => !ignored.has(c.path));
    }
    if (!changes.length) return { status: 'could_not_fix', note: 'claude made no change' };

    if (prMode) {
      // PROTECTED paths and the repo's own protectedPaths never change on a PR branch either (CI, env, agent instructions, hands config)
      const extraP = [...protectedFor(repoCfg), ...(cfg.osRepoSlug && slug.toLowerCase() === cfg.osRepoSlug.toLowerCase() ? [/^os\//] : [])];
      const hit = changes.find((c) => PROTECTED.test(c.path) || extraP.some((re) => re.test(c.path)));
      if (hit) return { status: 'could_not_fix', note: `question: the fix would touch protected path ${hit.path}; nothing pushed` };
    }

    // 5. the repo's own install + affected tests, in the work tree, no credential
    if (repoCfg.install) {
      const a = fill(repoCfg.install, { dir: W, repo: slug, base });
      r = await runUntrusted(a[0], a.slice(1), { timeoutMs: left() });
      if (r.timedOut) return { status: 'timed_out', note: 'install hit the cap' };
      if (r.code !== 0) return { status: 'could_not_fix', note: `install failed: ${oneLine(r.stderr || r.stdout)}` };
    }
    // from here on the tree belongs to the tests' uid: that code can no longer touch the Claude uid's files or memory
    if (cfg.testUser) await chownTo(cfg.testUser);
    const t = fill(repoCfg.test, { dir: W, repo: slug, base });
    r = await runUntrusted(t[0], t.slice(1), { timeoutMs: left(), role: 'tests' });
    if (r.timedOut) return { status: 'timed_out', note: 'tests hit the cap' };
    if (r.code !== 0) return { status: 'could_not_fix', note: `tests failed after the fix: ${oneLine(r.stdout + r.stderr)}` };

    // 6. lint/format classes: prove the diff is formatting-only by re-running the repo's formatter on the base files
    let formatting = { ok: false, reason: 'not a formatting class' };
    if (FORMAT_KINDS.has(kind)) formatting = await verifyFormattingOnly({ changes, repoCfg, W, cfg, runUntrusted, exec, step, left });

    // 7. secret scan of the diff + PR text before anything leaves the box
    const title = `fix(os): ${String(job.finding.title ?? job.finding.kind).replace(/\s+/g, ' ').slice(0, 80)}`.slice(0, 100);
    const summary = oneLine(text, 1500) || 'Automated fix by the Ebda OS hands.';
    const body = `${summary}\n\nFinding: ${job.finding.kind} ${job.finding.key}${job.finding.url ? `\n${job.finding.url}` : ''}\nJob: ${job.id}`;
    const leak = await secretScan({ changes, title, body, T, exec, cfg, step });
    if (leak) return { status: 'could_not_fix', note: `question: secret scan hit (${leak}); nothing pushed` };

    // 8. commit from the fresh tree, explicit paths only, hooks off; then it must be clean
    await applyChanges(C, changes);
    const paths = changes.map((c) => c.path);
    r = await git(C, ['add', '--', ...paths]);
    if (r.code !== 0) return { status: 'could_not_fix', note: `git add failed: ${oneLine(r.stderr)}` };
    r = await git(C, ['-c', `user.name=${cfg.gitName}`, '-c', `user.email=${cfg.gitEmail}`, 'commit', '-m', title, '-m', body, '-m', `Ebda-OS-Job: ${job.id}`]);
    if (r.code !== 0) return { status: 'could_not_fix', note: `commit failed: ${oneLine(r.stderr || r.stdout)}` };
    const sha = (await git(C, ['rev-parse', 'HEAD'])).stdout.trim();
    const clean = async () => (await git(C, ['status', '--porcelain=v1', '-z', '--untracked-files=all'])).stdout === '';
    if (!(await clean())) return { status: 'could_not_fix', note: 'commit tree has changes beyond the committed diff; nothing pushed' };
    // PR mode: a plain fast-forward push to the PR's own branch (no force, no -u), then stop: the hands never merge it
    r = await git(C, ['push', ...(prMode ? [] : ['-u']), 'origin', `HEAD:refs/heads/${prMode ? prHead : branch}`], { auth: true });
    if (r.code !== 0) return { status: 'could_not_fix', note: `push failed: ${oneLine(r.stderr)}` };
    if (prMode) return { status: 'pr_opened', prUrl: job.finding.url, note: `question: pushed a ${prState === 'conflicting' ? 'conflict resolution' : 'fix for the failing checks'} to ${prHead}; the hands never merge a PR` };

    // 9. PR (GH_TOKEN only in this process; cwd is the private dir, --repo explicit)
    const ghEnv = { PATH: env.PATH, HOME: T, GH_CONFIG_DIR: secrets.ghConfigDir, ...(creds.ghToken ? { GH_TOKEN: creds.ghToken } : {}), GH_PROMPT_DISABLED: '1' };
    r = await exec('gh', ['pr', 'create', '--repo', slug, '--base', base, '--head', branch, '--title', title, '--body', body], { cwd: T, env: ghEnv, timeoutMs: Math.max(1, Math.min(left() || 60_000, 5 * 60_000)) });
    const prUrl = (r.stdout.match(/https?:\/\/\S+\/pull\/\d+/) ?? [])[0];
    if (r.code !== 0 || !prUrl) return { status: 'could_not_fix', note: `branch ${branch} pushed but PR create failed: ${oneLine(r.stderr)}` };
    const pr = prUrl.split('/').pop();

    // 10. merge only when the declared class AND the actual diff allow it, and the repo gate (pristine workflows) is green
    const declared = mayAutoMerge(job);
    // the foundation repo itself: nothing under os/ (the OS the hands are part of) ever auto-merges
    const extra = [...protectedFor(repoCfg), ...(cfg.osRepoSlug && slug.toLowerCase() === cfg.osRepoSlug.toLowerCase() ? [/^os\//] : [])];
    const actual = declared.ok ? diffAllowsAutoMerge(kind, changes, extra, { pkg: String(job.finding.detail?.pkg ?? job.finding.title ?? '').split(/\s+/)[0] }) : declared;
    const why = !declared.ok
      ? declared.reason
      : !actual.ok
        ? actual.reason
        : FORMAT_KINDS.has(kind) && !formatting.ok
          ? `not verified formatting-only: ${formatting.reason}`
          : !repoCfg.mergeGate
            ? 'the repo has no merge gate configured'
            : !(await exists(BW))
              ? 'the base branch has no workflows for the merge gate'
              : null;
    if (why) return { status: 'pr_opened', prUrl, note: `question: ${why}; needs your review` };
    if (!(await clean())) return { status: 'pr_opened', prUrl, note: 'question: commit tree changed after the commit; not merging' };
    const gate = fill(repoCfg.mergeGate, { repo: slug, base, os_home: cfg.osHome, pr, sha, base_workflows: BW });
    log(`job ${job.id}: merge gate ${gate.join(' ')}`);
    // the gate may overrun the job cap by up to 60 s (it needs a few polls); accepted, documented in the README
    r = await exec(gate[0], gate.slice(1), { cwd: T, env: ghEnv, timeoutMs: Math.max(left(), 60_000) });
    if (r.code === 0) return { status: 'merged', prUrl, note: `pre-approved ${kind}; diff fits the class; merge gate green` };
    return { status: 'pr_opened', prUrl, note: `question: merge gate not green (exit ${r.code}${r.timedOut ? ', timed out' : ''}): ${oneLine(r.stderr || r.stdout, 200)}` };
  } finally {
    if (!ctx.keepWorkdir) await rm(jobDir, { recursive: true, force: true }).catch(() => {});
  }
}

/** Write the base version of each changed file into the work tree, run the repo's formatter on exactly those files, and
 *  require the result to equal Claude's version byte for byte. New or deleted files are never formatting-only. */
async function verifyFormattingOnly({ changes, repoCfg, W, cfg, runUntrusted, exec, step, left }) {
  if (!repoCfg.format) return { ok: false, reason: 'the repo has no format command configured' };
  if (changes.some((c) => c.type !== 'write' || !c.base)) return { ok: false, reason: 'the diff adds or deletes files' };
  for (const c of changes) await writeFile(join(W, c.path), c.base);
  if (cfg.sandboxUser) await exec('chown', [`${cfg.sandboxUser}:${cfg.sandboxUser}`, ...changes.map((c) => join(W, c.path))], { timeoutMs: step(60_000) });
  const a = fill(repoCfg.format, { dir: W }).flatMap((x) => (x === '{files}' ? changes.map((c) => c.path) : [x]));
  const r = await runUntrusted(a[0], a.slice(1), { timeoutMs: left(), role: 'tests' });
  if (r.code !== 0) return { ok: false, reason: `formatter exit ${r.code}` };
  for (const c of changes) {
    const after = await readFile(join(W, c.path)).catch(() => null);
    if (!after || !after.equals(c.buf)) return { ok: false, reason: `${c.path} differs from what the formatter produces` };
  }
  return { ok: true, reason: 'formatter reproduces the diff' };
}

/** Built-in patterns always; gitleaks too when installed. Returns a short reason or null. Never returns the secret. */
async function secretScan({ changes, title, body, T, exec, cfg, step }) {
  const written = changes.filter((c) => c.type === 'write');
  const hits = new Set(scanSecrets(`${title}\n${body}`));
  for (const c of written) for (const h of scanSecrets(c.buf.toString('utf8'))) hits.add(`${h} in ${c.path}`);
  if (hits.size) return [...hits].join(', ').slice(0, 300);
  if (!cfg.gitleaks) return null;
  const dir = join(T, 'scan');
  await rm(dir, { recursive: true, force: true });
  await mkdir(dir, { recursive: true, mode: 0o700 });
  for (const [i, c] of written.entries()) await writeFile(join(dir, `f${i}_${c.path.replace(/[^\w.-]/g, '_')}`), c.buf);
  await writeFile(join(dir, 'pr-text.txt'), `${title}\n${body}`);
  await chmod(dir, 0o700);
  const r = await exec(cfg.gitleaks, ['dir', dir, '--no-banner', '--redact', '--exit-code', '7'], { timeoutMs: step(5 * 60_000) });
  await rm(dir, { recursive: true, force: true });
  if (r.code === 7) return 'gitleaks found a secret';
  if (r.code !== 0) return `gitleaks failed (exit ${r.code}); refusing to push unscanned`;
  return null;
}
