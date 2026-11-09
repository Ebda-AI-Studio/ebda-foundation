# worktree-lifecycle — per-task worktree birth → merge → teardown

tags: [BOTH]
sources: CLAUDE.md ("Parallel-session orchestration — worktree-per-task"), memory/feedback-parallel-session-worktree-orchestration.md, memory/feedback-worktree-cleanup-github-pr-aware.md, memory/feedback-test-truncate-wiped-prod-db.md

## What "solid" looks like

Every session/task works in its OWN `git worktree` off fresh `origin/main`; the repo ROOT checkout stays on `main`, read-only. A worktree has a **full lifecycle that ends at merge**: the moment its PR is merged and nothing is broken/unpushed, the local worktree AND its branch are deleted — automatically, not "someday during cleanup." Abandoned worktrees are the #1 source of mess on the shared Force trees: root-owned leftovers that `EACCES` the self-hosted CI runners, tens of GB of stale dirs, and ~50 zombie `feat/*`/`fix/*`/`auto-fix/*` branches. The teardown is the safe inverse of `new-task-worktree.sh` and is gated so it can never destroy unsaved or unmerged work.

Two standing behaviors define the lifecycle:

1. **Delete the local worktree after merging — once it is proven nothing is broken.** Not at session end, not in a weekly sweep: right after the merge, behind verification gates.
2. **The common test files needed by every worktree are always kept.** The shared test-infra (prod-guards, integration setup, jest/vitest setup) lives on `main`, so every fresh worktree inherits it — and a teardown must never be the reason one goes missing. See `common-test-files.md`.

## The four teardown gates (`ops/post-merge-cleanup.sh`)

A worktree is torn down ONLY when all four pass; any failure → REFUSE, report, change nothing:

| # | Gate | Why | Detection |
|---|---|---|---|
| 1 | PR is **MERGED** on the remote | never delete work for an open/closed-unmerged PR | `gh pr view --json state` == `MERGED` |
| 2 | Worktree is **clean** | uncommitted changes = unsaved work; deleting loses it | `git status --porcelain` empty |
| 3 | **Nothing unpushed** | squash-merge means the branch tip is NOT an ancestor of main, so verify "fully pushed" instead: `HEAD == origin/<branch>` (or origin branch already consumed by `--delete-branch`) | compare `rev-parse HEAD` vs `origin/<branch>` |
| 4 | **Common test files intact** on the parent checkout | a teardown must never be why a shared prod-guard vanished | warn-only presence check against the `common-test-files.md` registry |

On success: `git worktree remove` → `git branch -D <branch>` → `git worktree prune`. The `worktree remove` itself refuses a dirty tree, so gate 2 is double-enforced.

## Criteria

| # | Criterion | Solid (grade 2) | Gap detection | Severity |
|---|---|---|---|---|
| 1 | Root checkout stays on main | repo ROOT (`~/Desktop/projects/<repo>`) is on `main`/`master`, never used to commit feature work | `git -C <root> rev-parse --abbrev-ref HEAD` is the default branch | Medium |
| 2 | One branch ↔ one worktree | every active branch maps to a `_worktrees/<repo>__<branch>` dir, created via `new-task-worktree.sh` | `git worktree list` per repo; flag feature branches checked out on the root | Medium |
| 3 | Post-merge teardown is automatic | after a merge the worktree+branch are deleted behind the 4 gates (`ops/post-merge-cleanup.sh <repo> <pr>`), not left for a manual sweep | merged-PR branch with a still-present `_worktrees/*` dir = gap | High |
| 4 | Teardown is gated, never blind | teardown refuses on dirty / unmerged / unpushed; uses GitHub MERGED state (squash-aware), not `merge-base --is-ancestor` (which misses squash-merges) | review the teardown script's gates; a blind `rm -rf` or ancestor-only check = gap | High |
| 5 | No zombie branches/worktrees | no merged-PR branch lingers locally; no `_worktrees/*` dir for a merged or abandoned branch beyond live work | `--sweep`/`--sweep-all` reports zero stale; `du -sh _worktrees` stays small | Medium |
| 6 | Common test files preserved | every repo keeps its shared test-infra (`common-test-files.md`); teardown's gate 4 confirms presence — **shape-aware since 2026-09-04**: where a repo has no destructive-reset path the applicable rule is crit 6 (a declared runner that reaches every suite), not the prod-guard, and gate 4 reports what it observed rather than asserting a destructiveness it cannot detect | see `common-test-files.md` criteria 1-2 (guard) and 6 (runner) | Critical |

## Ops

- `~/.claude/scripts/new-task-worktree.sh <repo> <feat|fix>/<task>` — birth: fresh worktree off `origin/main`.
- `ops/post-merge-cleanup.sh <owner/repo> <pr> [worktree-path]` — gated teardown of one merged PR's worktree.
- `ops/post-merge-cleanup.sh --sweep <owner/repo>` — tear down every merged+clean worktree of a repo.
- `ops/post-merge-cleanup.sh --sweep-all` — sweep every Force repo.
- `~/.claude/scripts/worktree-cleanup.sh` — branch-hygiene baseline (parks roots on main, kills git-ancestor branches). NOTE: it does NOT remove worktree dirs and MISSES squash-merged branches — `post-merge-cleanup.sh` is the disk-reclaiming, squash-aware complement.
- `ops/workspace-hygiene.sh` — the hourly safety-net sweep of the whole `_worktrees/` forest (launchd `com.ebda.os.workspace-hygiene`, every 3600s; since 2026-10-22 also fired repo-scoped and immediately after `gh pr merge` by `ops/hooks/post-merge-auto-cleanup.sh` via `--repo <slug> --skip <session worktree>`), independent of any single PR-merge event. Runs `worktree-cleanup.sh`, then removes clean worktrees whose branch is done — merged into `origin/main`/`origin/master` by ancestry, **or** (since 2026-07-12) whose branch has a GitHub PR in `MERGED` state, since the Force repos squash-merge by default and `merge-base --is-ancestor` never sees a squash merge. Also removes orphan dirs with no `.git` link, and reports (never touches) dirty/unpushed worktrees, cross-repo stashes, and disk totals. No per-worktree `git fetch` (worktrees share the repo object store; a fetch per tree timed the sweep out past ~20 trees) — relies on step 1's per-repo fetch. `DRY_RUN=1` previews. First real run reclaimed `_worktrees` from 38G to 6.1G.

## Standing rule for the remediation/merge loop

After any `gh pr merge` of a Force PR that was developed in a worktree, immediately run `ops/post-merge-cleanup.sh <owner/repo> <pr>`. It is safe to run unconditionally — it self-refuses if the PR isn't truly merged, the tree is dirty, or work is unpushed. This keeps `_worktrees/` to live work only and stops the zombie-branch/root-owned-leftover pileup at the source.
