# disk-discipline — two controls that keep the host disk (and the native CI runners on it) alive

tags: [BOTH]
sources: `feedback-umbra-sparse-disk-host-full-corrupts-guest`, `host-capacity-one-heavy-suite-and-guarded-umbra` (history; Umbra retired 2026-11-14)

Born from three disk-full incidents (2026-10-16, 2026-10-24, and a near miss 2026-10-25): the Mac's internal disk
filled. The native macOS CI runners share that disk (`_work` checkouts, `node_modules`), so a full host fails CI jobs
and degrades everything else. (Until 2026-11-14 a full host also corrupted the sparse disk image of the Umbra CI VM;
Umbra is retired, Ruling UMBRA-RETIRE-1.) The main thing that filled the disk was per-worktree installs, so the control is:

**The rule:** *every worktree gets its dependencies from `wt-deps.sh` (APFS clones of one cached install), by whatever
tool created it; and the hourly sweep removes merged worktrees and alerts before the host runs out.* A rule only in CLAUDE.md is a
preference, so each half is enforced in code.

**Tradeoff:** a worktree's `node_modules` is a copy-on-write clone — near-free until a file is written, but it is
not a symlink and a `npm install <pkg>` in it still costs real bytes.

## 1. Worktree dependencies come from the cache, never from a per-worktree install

Measured: ~0.2 GB per cloned worktree vs ~2.3 GB for `npm ci`; six parallel agent worktrees were the disk-full.

| Who creates a worktree | What catches it | Where |
|---|---|---|
| `new-task-worktree.sh` | calls `wt-deps.sh` directly | `ops/new-task-worktree.sh` |
| Raw `git worktree add`, EnterWorktree, Agent `isolation:"worktree"`, Codex, any tool, in a **trusted** repo **without** its own `core.hooksPath` | global `post-checkout` hook: a NEW linked worktree (previous HEAD all zeros **and** git-dir != git-common-dir) clones deps via `wt-deps.sh` (hook mode: clone-only) | `ops/git-hooks/dispatch.sh`, installed as `~/.claude/git-hooks/*` + `git config --global core.hooksPath` |
| Claude Code in a repo that **has** its own `core.hooksPath` (husky v9 sets `.husky/_`, which overrides the global path — git never calls the dispatcher there; measured) | PostToolUse on `EnterWorktree` and on Bash `git worktree add` runs `wt-deps.sh`; `wt-deps.sh` re-arms husky in the clone | `ops/hooks/post-worktree-deps.sh` |
| An agent running `npm ci` / `npm install` / `pnpm install` / `yarn install` in a worktree | PreToolUse **denies** it **only when a complete cache entry exists** for that lockfile and tells the agent to run `wt-deps.sh`. Cache miss (lockfile changed), `npm install <pkg>`, the main checkout, a subdir with its own lockfile and `WT_ALLOW_INSTALL=1` are all allowed | `ops/hooks/block-worktree-install.sh` + `wt-deps.sh --check` |
| Codex and other AIs | the same rule text in the generated `~/AGENTS.md` / `~/.codex/AGENTS.md` (source: `~/.claude/CLAUDE.md`, "Parallel sessions") | `ops/sync-agents-md.sh` |

The global dispatcher **chains** to the repo's LOCAL hook `<git-common-dir>/hooks/<name>` with `exec`, so stdin (pre-push)
and the exit status (pre-commit) pass through: a global `core.hooksPath` otherwise silently replaces every repo's
`.git/hooks`.

**Trust boundary (security review 2026-10-25).** A global hook runs for every repo, including a fresh clone of an
untrusted one, so it executes nothing that arrives inside a checkout:
- husky (`.husky/*`, tracked content) is chained ONLY where `git config --local ebda.chainHusky true` (set by
  `install.sh` on Ahmad's own repos); `node_modules/.bin` is never put on PATH;
- automatic dependency installs (git hook and Claude PostToolUse) run `wt-deps.sh` in HOOK MODE (`WT_DEPS_HOOK=1`):
  trusted repos only (ONE anchored validator, `ops/lib/trusted-origin.sh`: exact host github.com, org in OS_ORGS (os.env), one repo segment; AND the resolved real path under `~/Desktop/projects`), **CLONE-ONLY**: it copies an existing cache entry (built by a deliberate install) and on a cache MISS prints the manual command - no hook ever runs npm/pnpm/yarn (lockfile, `.npmrc`, registry, `.pnpmfile.cjs`, `yarnPath` are all repo-controlled code paths; a grep-based filter of them was shown bypassable), no husky re-arm; the cache key covers lockfile + package.json + origin url, and node_modules paths are NUL-listed, symlink-checked and kept inside the worktree;
- Claude hooks run `python3 -I` (a repo-local `json.py`/`shlex.py` must not shadow stdlib);
- a clone never triggers anything (post-checkout acts only on a linked worktree).

**Floor:** below `WT_MIN_FREE_GB` (30) the git and Claude hooks only clone from a cache hit — they never start a fresh
multi-GB install — and `new-task-worktree.sh` refuses outright (`WT_FORCE=1` overrides once).

**Known residual:** a non-Claude tool (Codex) doing a raw `git worktree add` inside a husky-style repo is not seen by
any git hook, only by the AGENTS.md rule. Settles with a PATH `git` wrapper if it ever happens.

## 2. Low host disk is alerted, not trimmed

`workspace-hygiene.sh` (hourly) removes merged + clean worktrees; when host free is under `WT_MIN_FREE_GB` (30) it sends
the Telegram alert (6 h cooldown) and `new-task-worktree.sh` refuses new worktrees. `ci-runner-guard.sh` also reads the
data volume every 30 min (note at 88% used, finding at 94%). `DRY_RUN=1` reports and removes nothing.

## 3. Grading (what an auditor checks)

- `git config --global core.hooksPath` is `~/.claude/git-hooks` and `post-checkout` there resolves to `dispatch.sh`.
- A raw `git worktree add` in a node repo leaves a populated `node_modules` of MBs of real bytes (`du`), not GBs.
- `block-worktree-install.sh` and `post-worktree-deps.sh` are registered in `~/.claude/settings.json` (dead-gate-detect enforces).
- Negative controls live in `ops/lib/__tests__/disk-discipline.test.sh` (miss allowed, `npm install <pkg>` allowed,
  repo pre-commit exit code propagates; workspace-hygiene has no VM step).
