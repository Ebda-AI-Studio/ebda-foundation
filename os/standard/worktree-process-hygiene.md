# worktree-process-hygiene - shared resources need an owner check before you touch them

tags: [BOTH]
sources: `worktree-process-and-handoff-hygiene`, `feedback-hygiene-sweep-deletes-fresh-zero-ahead-worktrees`, `feedback-worktree-cleanup-github-pr-aware`

Four 2026-10-25 incidents with one cause: an actor assumed a worktree / process / file / channel was its own.

**The rule:** *act only on what you can prove you own: a worktree you created, a PID you started, a file named for your session.* Each point has code or a guard.

**Tradeoff:** a few extra seconds (record a PID, name a role file) against a lost plan, a killed test queue or a clobbered handoff.

## 1. A new worktree is never 0-ahead
`worktree-lifecycle.md` removes a worktree once its PR is MERGED on GitHub. A branch created off `origin/main` with no
commit yet is *0 commits ahead* - indistinguishable from "fully merged" by ancestry - and the post-merge sweep deleted
a brand-new worktree with an uncommitted plan inside. Fixes, both live:
- **Detection** (foundation #254): "merged" = a GitHub PR in MERGED state at exactly this tip (`lib/wt-safety.sh`); a branch with no commit beyond main is NEW; **untracked files count as dirty**; removal never uses `--force`.
- **Creation** (`ops/new-task-worktree.sh`): a NEW branch gets `git commit --allow-empty -m "chore: start <branch>"` immediately, so it is one commit ahead from its first second. Resuming an existing branch adds nothing. Non-fatal if a hook refuses it (the script prints the manual command). Test: `ops/tests/new-task-worktree.test.sh`.
A worktree made some other way (raw `git worktree add`, Codex): make the empty commit yourself.

## 2. Kill only PIDs you started
An agent ran `pkill -f "<pattern>"` for cleanup; the pattern matched *other agents'* processes and killed their queued
test runs. Rules (also in the generated AGENTS.md):
- Record the PID when you start something (`cmd & pid=$!`), verify with `ps -o pid,ppid,command -p <pid>`, kill exactly that PID and its descendants.
- Never `pkill`/`killall`/`pkill -f` by name or pattern, never "kill whatever holds port N" without checking the owner is yours.
- If you must stop something you did not start, ask the owner (the controller session) - and say what and why.

## 3. Handoff files belong to one session
Subagents inherit the controller's session id, so their handoff writes landed on the controller's `<session-id>.md` and
overwrote it. Convention (`session-handoff.md`): a subagent writes `~/.claude/handoff/<session-id>-<role>.md`.
Enforced by `ops/hooks/block-handoff-clobber.sh` (PreToolUse, registered by `ops/install-hooks.sh`): denies a write to another session's handoff, and a *subagent's* write to the bare controller file. Test: `ops/tests/block-handoff-clobber.test.sh`.
Residual: where a Claude Code version omits `agent_id`/`agent_type` on subagent tool calls, only the cross-session rule fires; the role-file convention then relies on the brief. Settles by checking one real subagent payload.

## 4. Remote Control: `!` does not run
A `! command` typed from the phone (Remote Control) arrives as plain text and does NOT execute. Never answer a blocker
with "type `! cmd`"; run it yourself, or give Ahmad a plain instruction he can follow from a phone.

## 5. The root checkout refuses commits and merge commits
2026-11-23, twice: `cd <worktree> && git merge ...` failed at the `cd`, so `git merge` ran in the ROOT checkout and moved local main ahead of origin. The Claude PreToolUse hook `block-root-checkout-commit.sh` only sees `git commit` typed in a Bash call; it cannot see a merge, a Codex run or a script. The global git hook can.
The logic is the standalone `ops/root-checkout-guard.sh <pre-commit|pre-merge-commit|post-merge>`, called by `ops/git-hooks/dispatch.sh` (installed as every hook name, so `pre-commit`, `pre-merge-commit`, `post-merge` already exist). It REFUSES `pre-commit` and `pre-merge-commit` (exit 1, message names `new-task-worktree.sh`) when ALL hold: main worktree (`git-dir == git-common-dir`), path under `$OS_PROJECTS_DIR/*/internal-projects/*` or `*/clients/*/*`, HEAD is `main`/`master`. Linked worktrees, feature branches, repos outside the slots and detached HEAD are never blocked.
- **Fast-forward stays allowed, on purpose.** A ff merge runs no `pre-merge-commit`, and `git merge --ff-only origin/main` is the legitimate way to keep root current. Only a merge that CREATES a commit (non-ff, or a conflict resolution commit) is refused.
- **Residual (measured by `ops/tests/root-checkout-guard.test.sh`):** a ff merge of a LOCAL unpushed branch also moves root main ahead and cannot be refused (indistinguishable from the legitimate ff at hook time). `post-merge` prints a loud WARNING when root main is no longer contained in `origin/main`; it cannot undo. `reference-transaction` was considered and rejected: it fires for every ref update with no view of the command, and aborting mid-transaction is worse than a warning.
- **Escape hatch:** `EBDA_ALLOW_ROOT_COMMIT=1` (each use appended to `~/Library/Logs/root-commit-guard.log`). Takes effect only after `ops/install.sh` re-copies `dispatch.sh` to `~/.claude/git-hooks`.
- **Repos with their own `core.hooksPath` (husky) never reach the dispatcher** (ebda-store measured 2026-11-23): they vendor `root-checkout-guard.sh` and call it from `.husky/pre-commit` and `.husky/pre-merge-commit`.

## Grading
| # | Criterion | Check | Severity |
|---|---|---|---|
| 1 | New branches carry a start commit | `rev-list --count origin/main..HEAD` >= 1 right after `new-task-worktree.sh` | High |
| 2 | Sweep never removes a new/dirty/untracked worktree | `ops/tests/workspace-hygiene.test.sh` | High |
| 3 | No pattern-based kills in scripts or agent transcripts | `grep -rnE "pkill|killall" ops` shows only PID-scoped or own-process-group uses | Medium |
| 4 | Handoff guard registered | `block-handoff-clobber.sh` in `~/.claude/settings.json` hooks; `dead-gate-detect.sh` passes | Medium |
| 5 | Root checkout refuses commit + merge commit | `ops/tests/root-checkout-guard.test.sh` (18 checks incl. ff allowed, hatch logged) | High |
