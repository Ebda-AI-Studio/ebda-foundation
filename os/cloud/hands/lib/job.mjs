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
import { expectedApiKeySource } from './auth.mjs';
import { costOf, priceTable } from './prices.mjs';

export { PROTECTED } from './diffcheck.mjs';

const DEP_KINDS = new Set(['dep-bump', 'dependency-advisory', 'cve-bump', 'lockfile-drift']);

export function oneLine(s, n = 300) {
  return String(s ?? '').replace(/\s+/g, ' ').trim().slice(-n);
}

/** Claude permission flags. Edits are scoped to the checkout; CI, env, .git and test-defining files are denied (the diff
 *  check enforces the same rule independently: a denied path in the diff = no auto-merge). */
/** F-03: the checked-out repo's own Claude settings are NOT loaded (in -p mode there is no trust dialog, so its hooks, `env` block, apiKeyHelper
 *  and .mcp.json servers would otherwise run); hooks are off, MCP is empty and strict. A repo `.claude/settings.json` can therefore neither run
 *  code as Claude's uid nor switch the credential. (Flags to be re-verified on the pinned CLI: `claude --help`.) */
export const CLAUDE_ISOLATION = ['--setting-sources', 'user', '--settings', '{"disableAllHooks":true}', '--strict-mcp-config', '--mcp-config', '{"mcpServers":{}}'];

export function claudePermissionArgs(cfg, repoCfg, kind) {
  const deny = ['.git/**', '.github/**', '.env*', '**/.env*', '**/vitest.config.*', '**/jest.config.*', '**/playwright.config.*', '**/CLAUDE.md', '**/AGENTS.md', '**/GEMINI.md', '.claude/**', '.agents/**', '.cursor/**', '.husky/**', ...(repoCfg.protectedPaths ?? [])];
  if (!DEP_KINDS.has(kind)) deny.push('**/package.json');
  const denyRules = deny.flatMap((p) => [`Edit(./${p})`, `Write(./${p})`]);
  if (cfg.sandboxed) return [...CLAUDE_ISOLATION, '--permission-mode', 'bypassPermissions', '--disallowedTools', denyRules.join(',')];
  const allow = ['Read(./**)', 'Edit(./**)', 'Write(./**)', 'Glob', 'Grep', `Bash(${repoCfg.test.join(' ')}:*)`];
  return [...CLAUDE_ISOLATION, '--permission-mode', 'acceptEdits', '--allowedTools', allow.join(','), '--disallowedTools', [...denyRules, 'WebFetch', 'WebSearch'].join(',')];
}

async function exists(p) {
  try {
    await stat(p);
    return true;
  } catch {
    return false;
  }
}

/** Dotfiles through which a previous job's code (a postinstall, a test) could steer the NEXT job's Claude or install: Claude's own
 *  settings / hooks / memory / CLAUDE.md, and the package-manager and shell config. Container only: on the Mac the home is Ahmad's. */
const HOME_PLANTS = ['.claude', '.claude.json', '.npmrc', '.yarnrc', '.yarnrc.yml', '.bashrc', '.profile', '.bash_profile', '.gitconfig', '.config', '.npm', '.cache'];

/** Remove the planted-file candidates from every unprivileged home and verify they are gone. Returns a reason or null. */
export async function scrubSandboxHomes(cfg) {
  if (!cfg.sandboxUser) return null;
  const homes = [...new Set([cfg.sandboxHome, cfg.testHome, cfg.testUser ? `/home/${cfg.testUser}` : ''].filter(Boolean))];
  for (const h of homes) {
    for (const n of HOME_PLANTS) {
      const p = join(h, n);
      await rm(p, { recursive: true, force: true }).catch(() => {});
      if (await exists(p)) return `could not clean ${p} between jobs`;
    }
  }
  return null;
}

/** Every process of the unprivileged uids (Claude's and the tests') dies between jobs, so a backgrounded postinstall or test helper cannot
 *  outlive its job and watch or act in the next. Scoped by uid (never by name pattern) and verified: returns a reason if any is left. */
export async function killUntrustedProcesses(cfg, exec) {
  if (!cfg.sandboxUser) return null;
  for (const u of [...new Set([cfg.sandboxUser, cfg.testUser].filter(Boolean))]) {
    for (let i = 0; i < 5; i++) {
      await exec('pkill', ['-KILL', '-u', u], { timeoutMs: 10_000 });
      const left = await exec('pgrep', ['-u', u], { timeoutMs: 10_000 });
      if (left.code === 1) break; // pgrep: 1 = no process matched
      if (i === 4) return `processes of ${u} survived the end-of-job kill`;
      await new Promise((r) => setTimeout(r, 100));
    }
  }
  return null;
}

/** Dollars one job cost, from the result event(s): per model when the event breaks it down, else the aggregate x the routed model. */
export function jobUsage(result, model, table) {
  if (!result) return null;
  const mu = result.modelUsage && typeof result.modelUsage === 'object' ? Object.entries(result.modelUsage) : [];
  if (mu.length) {
    const parts = mu.map(([m, u]) => costOf({ input_tokens: u.inputTokens, output_tokens: u.outputTokens, cache_read_input_tokens: u.cacheReadInputTokens, cache_creation_input_tokens: u.cacheCreationInputTokens }, m, table));
    const top = parts.slice().sort((a, b) => b.costUsd - a.costUsd)[0];
    return { model: top.model, inputTokens: parts.reduce((a, x) => a + x.inputTokens, 0), outputTokens: parts.reduce((a, x) => a + x.outputTokens, 0), cacheReadTokens: parts.reduce((a, x) => a + x.cacheReadTokens, 0), cacheWriteTokens: parts.reduce((a, x) => a + x.cacheWriteTokens, 0), costUsd: Math.round(parts.reduce((a, x) => a + x.costUsd, 0) * 1e6) / 1e6 };
  }
  return result.usage ? costOf(result.usage, model, table) : null;
}

export async function runJob(job, ctx) {
  const acc = {};
  const out = await runJobCore(job, ctx, acc);
  // every outcome after a Claude run carries what that run cost (the brain keeps the daily / monthly totals and halts at the budget)
  return acc.usage ? { ...out, usage: acc.usage } : out;
}

const MODELS = new Set(['haiku', 'sonnet', 'opus']);

async function runJobCore(job, ctx, acc) {
  const { cfg, exec, usage, log = () => {}, now = () => Date.now(), env = process.env, creds = {} } = ctx;
  const slug = job.finding?.repo;
  const ghToken = creds.ghTokens?.[String(slug ?? '').split('/')[0]] ?? creds.ghToken;
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
  const testHome = cfg.testUser ? (cfg.testHome || `/home/${cfg.testUser}`) : sandboxHome;
  const runUntrusted = (cmd, args, o = {}) => {
    const role = o.role ?? 'claude';
    const [c, a] = asSandbox(cfg, cmd, args, role);
    return exec(c, a, { cwd: W, ...o, env: untrustedEnv(env, { HOME: role === 'tests' ? testHome : sandboxHome, ...((role === 'tests' ? cfg.proxyEnvTests : cfg.proxyEnv) ?? {}), ...(o.extraEnv ?? {}) }) });
  };
  const chownTo = (user) => (cfg.sandboxUser && user ? exec('chown', ['-R', `${user}:${user}`, W], { timeoutMs: step(60_000) }) : null);

  try {
    await rm(jobDir, { recursive: true, force: true });
    await mkdir(jobDir, { recursive: true, mode: 0o755 });
    // N-3b: what the previous job's code left in the unprivileged homes must not steer this job's Claude or install
    const survivors = await killUntrustedProcesses(cfg, exec);
    if (survivors) return { status: 'could_not_fix', note: survivors };
    const dirty = await scrubSandboxHomes(cfg);
    if (dirty) return { status: 'could_not_fix', note: dirty };
    const secrets = await prepareJobSecrets(T);
    const git = (cwd, args, o = {}) => exec('git', [...safe, ...args], { cwd, timeoutMs: step(), env: gitEnv(env, secrets, { token: ghToken, auth: o.auth }) });
    const url = cloneUrl(cfg.gitHost ?? 'https://github.com', slug, ghToken);

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
    let badAuthSource = null;
    // model routing: the brain's per-job choice (haiku | sonnet | opus), else the configured default; recorded with the cost
    const model = MODELS.has(job.model) ? job.model : cfg.claudeModel;
    const table = priceTable(env);
    const mode = cfg.claudeAuth ?? (creds.claudeToken ? 'max' : 'login');
    log(`job ${job.id}: claude (${model}, auth ${mode}, cap ${Math.round(left() / 60000)} min)`);
    // credential: api -> the placeholder + the loopback forwarder (it holds the real key), or the key itself when the forwarder is off;
    // max -> the OAuth token on fd 3; login (Mac) -> nothing, the CLI's own login
    const authEnv = mode === 'api' ? (cfg.anthropicBaseUrl ? { ANTHROPIC_BASE_URL: cfg.anthropicBaseUrl, ANTHROPIC_API_KEY: cfg.anthropicPlaceholderKey } : { ANTHROPIC_API_KEY: creds.apiKey }) : creds.claudeToken ? { CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR: '3' } : {};
    r = await runUntrusted(cfg.claudeBin, ['-p', prompt, '--output-format', 'stream-json', '--verbose', '--model', model, '--max-turns', String(cfg.maxTurns), ...claudePermissionArgs(cfg, repoCfg, kind)], {
      timeoutMs: left(),
      ...(mode === 'max' && creds.claudeToken ? { fd3: creds.claudeToken } : {}),
      extraEnv: { CLAUDE_CODE_SUBPROCESS_ENV_SCRUB: '1', DISABLE_AUTOUPDATER: '1', CLAUDE_CODE_MAX_OUTPUT_TOKENS: String(cfg.maxOutputTokens ?? 16000), ...authEnv },
      onLine: (line) => {
        let ev;
        try {
          ev = JSON.parse(line);
        } catch {
          return;
        }
        usage?.observe(ev);
        // F-06: the init event names where the credential came from; anything but the expected source aborts the job (checked when present)
        if (ev.type === 'system' && ev.subtype === 'init' && typeof ev.apiKeySource === 'string' && ev.apiKeySource !== expectedApiKeySource(mode)) badAuthSource = ev.apiKeySource;
        if (ev.type === 'result') result = ev;
      },
    });
    acc.usage = jobUsage(result, model, table);
    if (badAuthSource) return { status: 'could_not_fix', note: `claude authenticated from '${badAuthSource}', expected '${expectedApiKeySource(mode)}'; aborted (billable-credential tripwire)` };
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
    if (changes.length > (cfg.maxChangedFiles ?? 200)) return { status: 'could_not_fix', note: `question: ${changes.length} changed files is not a targeted fix` };
    const bytes = changes.reduce((a, c) => a + (c.buf?.length ?? 0), 0);
    if (bytes > (cfg.maxChangedBytes ?? 1024 * 1024)) return { status: 'could_not_fix', note: `question: ${bytes} changed bytes is not a targeted fix` };
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
      // N-3b: a postinstall is the repo's (or a dependency's) code, so it runs as the tests uid with the tree handed to it first,
      // never as Claude's uid (which would let it plant ~/.claude settings or hooks for the next run)
      if (cfg.testUser) await chownTo(cfg.testUser);
      r = await runUntrusted(a[0], a.slice(1), { timeoutMs: left(), role: 'tests' });
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

    // 7b. I-8: the PR's CI runs with the repo's secrets (a hands PR is same-repo). If a PR-triggered workflow of the BASE branch lets PR code
    // reach one, nothing is pushed at all: ask instead. Checked on the pristine base workflows, never the edited tree. Fails closed.
    if (await exists(BW)) {
      r = await exec('python3', ['-I', join(cfg.osHome, 'ops', 'lib', 'merge_gate.py'), 'secrets-exposure', BW], { timeoutMs: step(60_000) });
      let exposed = null;
      try {
        exposed = JSON.parse(r.stdout);
      } catch {}
      if (r.code !== 0 || !Array.isArray(exposed)) return { status: 'could_not_fix', note: 'question: could not check the repo workflows for secrets reachable from a PR; nothing pushed' };
      if (exposed.length) return { status: 'could_not_fix', note: `question: a PR-triggered workflow lets PR code reach repo secrets (${exposed.slice(0, 3).join(', ')}), so a hands PR's CI would run with them; nothing pushed` };
    }

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
    const ghEnv = { PATH: env.PATH, HOME: T, GH_CONFIG_DIR: secrets.ghConfigDir, ...(ghToken ? { GH_TOKEN: ghToken } : {}), GH_PROMPT_DISABLED: '1' };
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
    // I-8: a hands PR is same-repo, so its CI gets the repo secrets; --hands makes the gate refuse where a PR-triggered workflow lets PR code reach one
    if (gate.some((a) => /merge-gate\.sh$/.test(a)) && !gate.includes('--hands')) gate.push('--hands');
    log(`job ${job.id}: merge gate ${gate.join(' ')}`);
    // the gate may overrun the job cap by up to 60 s (it needs a few polls); accepted, documented in the README
    r = await exec(gate[0], gate.slice(1), { cwd: T, env: ghEnv, timeoutMs: Math.max(left(), 60_000) });
    if (r.code === 0) return { status: 'merged', prUrl, note: `pre-approved ${kind}; diff fits the class; merge gate green` };
    return { status: 'pr_opened', prUrl, note: `question: merge gate not green (exit ${r.code}${r.timedOut ? ', timed out' : ''}): ${oneLine(r.stderr || r.stdout, 200)}` };
  } finally {
    if (!ctx.keepWorkdir) await rm(jobDir, { recursive: true, force: true }).catch(() => {});
    await killUntrustedProcesses(cfg, exec).catch(() => {});
    await scrubSandboxHomes(cfg).catch(() => {});
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
