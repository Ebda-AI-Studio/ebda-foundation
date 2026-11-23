#!/usr/bin/env bash
# post-merge-cleanup.sh — Whisky AI OS post-merge worktree teardown.
#
# WHY: a worktree is a per-task checkout (one branch <-> one worktree <-> one
# session). Once its PR is MERGED, the worktree is dead weight — and abandoned
# worktrees are the #1 source of mess on the shared Force trees (root-owned
# leftovers EACCES-ing CI runners, GBs of stale dirs, ~50 zombie branches).
# This script does what a human kept forgetting: AFTER a merge, once it is
# proven nothing is broken/unpushed, DELETE the local worktree + its branch.
#
# It is the safe inverse of new-task-worktree.sh.
#
# SAFETY GATES (refuse teardown unless ALL pass):
#   1. The PR is genuinely MERGED on the remote (state==MERGED, not just closed).
#   2. The worktree is CLEAN — zero uncommitted changes (no unsaved work lost).
#   3. Nothing is unpushed — local branch HEAD == origin/<branch> (every commit
#      the PR claimed is on the remote; squash-merge means the branch tip is NOT
#      an ancestor of main, so we verify "fully pushed" instead of "merged-in").
#   4. The repo's COMMON TEST FILES (prod-guards + shared setup, see
#      standard/common-test-files.md) still exist on the parent checkout — a
#      teardown must never be the reason a shared guard goes missing.
# Any gate failing => REFUSE, exit non-zero, touch nothing.
#
# Usage:
#   ops/post-merge-cleanup.sh <owner/repo> <pr-number> [worktree-path]
#   ops/post-merge-cleanup.sh --sweep <owner/repo>      # tear down every merged+clean worktree of the repo
#   ops/post-merge-cleanup.sh --sweep-all               # sweep every Force repo
#
# Examples:
#   ops/post-merge-cleanup.sh $OS_ORG/ebda-studio 23
#   ops/post-merge-cleanup.sh --sweep $OS_ORG/ebda-whatsapp
#
# Exit codes:
#   0 — teardown done (or nothing to do)
#   1 — fatal (bad args / missing tools)
#   2 — REFUSED a teardown (gate failed) — reported, nothing changed
#
# Requirements: bash >=3.2 (macOS default), gh, git
# shellcheck source=lib/os-config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/os-config.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-config.sh" 2>/dev/null || true
command -v os_config_load >/dev/null 2>&1 && os_config_load
set -uo pipefail
# S0 (2026-10-26): --help runs nothing; one run at a time (lib/single-instance.sh)
. "$(dirname "${BASH_SOURCE[0]}")/lib/args.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/args.sh" || exit 2
. "$(dirname "${BASH_SOURCE[0]}")/lib/single-instance.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/single-instance.sh" || exit 2
args_help "${BASH_SOURCE[0]}" "$@"
single_instance_wait post-merge-cleanup 120
. "$(dirname "$0")/lib/os-state.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-state.sh" 2>/dev/null || true
. "$(dirname "$0")/lib/wt-safety.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/wt-safety.sh" 2>/dev/null || { echo "post-merge-cleanup: lib/wt-safety.sh missing; refusing to tear anything down" >&2; exit 2; }

# TCC canary (2026-07-12): abort when the launchd context cannot see ~/Desktop
OS_JOB_NAME=post-merge-cleanup
if command -v require_projects_access >/dev/null 2>&1; then require_projects_access || exit 0; fi


GH_USER="$OS_ORG"
PROJECTS_ROOT="$OS_PROJECTS_DIR"
WORKTREES_ROOT="$PROJECTS_ROOT/_worktrees"   # internal root; sweep_repo also walks the SSD root
. "$(dirname "${BASH_SOURCE[0]}")/lib/wt-roots.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/wt-roots.sh" 2>/dev/null || true

# Common test-infra files that MUST exist in every Force repo (see
# standard/common-test-files.md). The canonical one is the destructive-reset
# prod-guard whose ABSENCE wiped the whatsapp prod DB (feedback-test-truncate-wiped-prod-db).
# Globs are checked as "at least one match exists"; a repo only needs the ones
# that apply to its test stack, so a miss is a WARNING, not a teardown blocker —
# but it is always reported so the gap gets propagated, never silently lost.
COMMON_TEST_GLOBS='tests/setup*.ts tests/setup*.js tests/integration/setup.ts jest.setup.* vitest.setup.* tests/helpers/prod-guard.* tests/**/guard*.* '

# 2026-09-04 — the globs above are jest/vitest/Prisma-shaped, so a repo whose
# test stack is bash + node-ESM + python (this one: ebda-foundation, 38
# suites, no database) could never match ANY of them. The gate warned on every
# teardown about a prod-guard that is genuinely N/A there, while the real gap —
# 13 suites run by nothing, one of them RED for weeks — went unmentioned. An
# alert that fires on the shape of the checker rather than the state of the
# world is measuring itself (feedback-monitor-alert-measures-the-monitor).
#
# The fix does NOT try to auto-classify "does this repo run a destructive
# reset?" by grep. That was tried and produced three false-positive classes on
# its FIRST run: the pattern matched its own definition line (the pgrep-self-
# match shape), the word TRUNCATED in prose and docstrings, and SQL-INJECTION
# TEST FIXTURES (`"'; DROP TABLE users; --"`) — which are the opposite of a
# destructive path. A gate that accuses every repo is worth less than no gate.
#
# So gate 4 reports what it OBSERVED and names what would settle the rest:
#   - a guard/setup file matched            -> pass, silently
#   - none matched, but a declared runner    -> pass, saying prod-guard is
#     unverified here and crit 1-2 must be checked by a human if the repo has a
#     destructive path
#   - none matched, tests exist, no runner   -> warn: a suite nobody runs
# Never an assertion about destructiveness this check cannot actually make.
TEST_RUNNER_GLOBS='ops/run-tests.sh scripts/test.sh Makefile package.json '

err()  { printf '\033[31m%s\033[0m\n' "$*" >&2; }
ok()   { printf '\033[32m%s\033[0m\n' "$*"; }
warn() { printf '\033[33m%s\033[0m\n' "$*"; }
info() { printf '%s\n' "$*"; }

command -v gh  >/dev/null 2>&1 || { err "gh not found"; exit 1; }
command -v git >/dev/null 2>&1 || { err "git not found"; exit 1; }

# local_dir <gh-slug> -> local checkout dir name (handles the two aliases).
local_dir() {
  case "$1" in
    ebda-whatsapp) echo "ebda-whatsapp" ;;
    ebda-studio)      echo "ebda-studio" ;;
    *)                    echo "$1" ;;
  esac
}

# Resolve a repo's primary (root) checkout path from its gh slug.
repo_root_path() {
  local slug_only="${1#*/}"
  resolve_repo_dir "$(local_dir "$slug_only")" 2>/dev/null || echo "$PROJECTS_ROOT/$(local_dir "$slug_only")"
}

# Check the common test files exist somewhere in a checkout. Reports missing
# ones (warning only) so the gap can be propagated. Never blocks teardown.
check_common_test_files() {
  local checkout="$1" g hit repo has_tests runner=""
  [ -d "$checkout" ] || return 0
  repo="$(basename "$checkout")"

  # 1. A guard/setup file is present -> solid, say nothing.
  for g in $COMMON_TEST_GLOBS; do
    # at least one file matching the glob (shell-glob, nullglob-safe)
    hit=$(cd "$checkout" 2>/dev/null && ls -d $g 2>/dev/null | head -1)
    [ -n "$hit" ] && return 0
  done

  # 2. No guard file. Does the repo even have suites? No suites -> nothing to say.
  has_tests=$(find "$checkout" \( -name '*.test.*' -o -name '*_test.*' \
                -o -name 'test_*' -o -name '__tests__' \) \
                -not -path '*/node_modules/*' -not -path '*/.git/*' \
                2>/dev/null | head -1)
  [ -n "$has_tests" ] || return 0

  # 3. Is there a declared entry point that reaches them?
  for g in $TEST_RUNNER_GLOBS; do
    hit=$(cd "$checkout" 2>/dev/null && ls -d $g 2>/dev/null | head -1)
    [ -n "$hit" ] && { runner="$hit"; break; }
  done

  if [ -z "$runner" ]; then
    warn "   ⚠ $repo has test files but NO declared runner — nothing invokes them"
    warn "     -> standard/common-test-files.md crit 6. A suite nobody runs reads as coverage."
    return 0
  fi

  # Observed, not diagnosed: the runner exists; the prod-guard question is open
  # and a human settles it, because this check cannot.
  info "   ℹ gate 4 — no prod-guard/setup file matched in $repo; suites are reachable via $runner."
  info "     If this repo runs a destructive reset (TRUNCATE / deleteMany / --force-reset)"
  info "     against a real DB, crit 1-2 apply — check the reset path and propagate the guard."
  return 0
}

# teardown_one <slug> <pr> [worktree-path]
# Runs the 4 gates; on success removes the worktree + branch.
teardown_one() {
  local slug="$1" pr="$2" wt="${3:-}"
  local owner_repo="$slug"
  case "$slug" in */*) ;; *) owner_repo="$GH_USER/$slug" ;; esac
  local repo_only="${owner_repo#*/}"

  info "── $owner_repo#$pr ─────────────────────────────"

  # --- PR metadata ---
  local meta state merged_at head_ref pr_head_oid
  meta=$(gh pr view "$pr" --repo "$owner_repo" --json state,mergedAt,headRefName,headRefOid 2>/dev/null) || {
    err "   ✖ cannot read PR $owner_repo#$pr"; return 2; }
  state=$(printf '%s' "$meta"   | sed -n 's/.*"state":"\([^"]*\)".*/\1/p')
  head_ref=$(printf '%s' "$meta" | sed -n 's/.*"headRefName":"\([^"]*\)".*/\1/p')
  pr_head_oid=$(printf '%s' "$meta" | sed -n 's/.*"headRefOid":"\([^"]*\)".*/\1/p')

  # GATE 1 — must be MERGED
  if [ "$state" != "MERGED" ]; then
    err "   ⛔ GATE 1 FAIL — PR state is '$state', not MERGED. Refusing teardown."
    return 2
  fi
  ok "   ✓ gate 1 — PR is MERGED (branch: $head_ref)"

  # --- resolve the worktree ---
  if [ -z "$wt" ]; then
    # find the worktree whose checked-out branch == head_ref
    local root; root=$(repo_root_path "$owner_repo")
    if [ -d "$root/.git" ] || [ -f "$root/.git" ]; then
      wt=$(git -C "$root" worktree list --porcelain 2>/dev/null \
        | awk -v b="refs/heads/$head_ref" '
            /^worktree /{p=$2} /^branch /{if($2==b) print p}' | head -1)
    fi
  fi
  if [ -z "$wt" ] || [ ! -d "$wt" ]; then
    warn "   ⚠ no local worktree found for branch '$head_ref' — nothing to remove (already cleaned?)."
    # still try to delete a stale local branch on the root
    local root; root=$(repo_root_path "$owner_repo")
    git -C "$root" branch -D "$head_ref" >/dev/null 2>&1 && ok "   ✓ deleted stale local branch '$head_ref'"
    return 0
  fi
  info "   worktree: $wt"

  # parent (common) checkout that owns this worktree
  local common parent
  common=$(git -C "$wt" rev-parse --git-common-dir 2>/dev/null)
  parent=$(cd "$wt" && cd "$(dirname "$common")" && pwd)

  # GATE 2 — worktree clean
  local dirty
  dirty=$(wt_dirty_count "$wt")
  if [ "$dirty" != "0" ]; then
    err "   ⛔ GATE 2 FAIL — worktree has $dirty uncommitted change(s). Refusing (would lose work)."
    git -C "$wt" status --short | sed 's/^/        /' >&2
    return 2
  fi
  ok "   ✓ gate 2 — worktree is clean"

  # GATE 2b — this worktree's HEAD is EXACTLY the merged PR's head commit. The PR is matched by BRANCH NAME, and a
  # name can be reused: a brand-new branch with the same name (or one sitting at origin/main with zero commits)
  # must never be torn down because an OLD PR of that name merged (2026-10-25: a new worktree and its uncommitted
  # plan were deleted that way). Anything else is new or in-flight work: keep.
  if [ -n "$pr_head_oid" ] && [ "$(git -C "$wt" rev-parse HEAD 2>/dev/null)" != "$pr_head_oid" ]; then
    err "   ⛔ GATE 2b FAIL — worktree HEAD $(git -C "$wt" rev-parse --short HEAD 2>/dev/null) is not the merged PR's head ${pr_head_oid:0:7}: new or in-flight work on a reused branch name. Refusing."
    return 2
  fi
  ok "   ✓ gate 2b — HEAD is the merged PR's head"

  # GATE 3 — nothing unpushed (local branch tip == origin/<branch>, OR origin
  # branch already deleted by --delete-branch, in which case the merge consumed it)
  local local_sha remote_sha
  local_sha=$(git -C "$wt" rev-parse HEAD 2>/dev/null)
  remote_sha=$(git -C "$wt" rev-parse "origin/$head_ref" 2>/dev/null || true)
  if [ -n "$remote_sha" ] && [ "$local_sha" != "$remote_sha" ]; then
    # local has commits the remote branch never saw -> unpushed work
    if ! git -C "$wt" merge-base --is-ancestor "$local_sha" "$remote_sha" 2>/dev/null; then
      err "   ⛔ GATE 3 FAIL — local branch has unpushed commit(s) (HEAD $local_sha != origin $remote_sha). Refusing."
      return 2
    fi
  fi
  ok "   ✓ gate 3 — nothing unpushed"

  # GATE 4 — common test files intact on the parent checkout (warn-only)
  check_common_test_files "$parent"

  # --- all gates passed: remove worktree + branch ---
  # NO --force fallback: git refuses to remove a tree that gained modified/untracked files since gate 2 (the file may
  # have been written in the seconds between the check and here). Keep it for manual review instead of losing it.
  if git -C "$parent" worktree remove "$wt" 2>/dev/null; then
    ok "   ✓ removed worktree"
  else
    err "   ✖ could not remove worktree $wt — leaving in place for manual review"
    return 2
  fi
  git -C "$parent" branch -D "$head_ref" >/dev/null 2>&1 && ok "   ✓ deleted local branch '$head_ref'"
  git -C "$parent" worktree prune 2>/dev/null
  ok "   ✓ teardown complete"
  return 0
}

# sweep_repo <slug> — tear down every worktree of the repo whose branch has a MERGED PR and is clean.
sweep_repo() {
  local slug="$1"
  local owner_repo="$slug"
  case "$slug" in */*) ;; *) owner_repo="$GH_USER/$slug" ;; esac
  local repo_only="${owner_repo#*/}"
  local dir; dir=$(local_dir "$repo_only")

  info "═══ sweep $owner_repo ═══"
  # merged-PR branch set
  local merged
  merged=$(gh pr list --repo "$owner_repo" --state merged --limit 400 \
    --json headRefName,number -q '.[] | "\(.headRefName)\t\(.number)"' 2>/dev/null)
  if [ -z "$merged" ]; then info "   (no merged PRs / repo unreachable) — skip"; return 0; fi

  # every worktree dir for this repo under _worktrees
  local any=0 wt br pr_line pr
  local _roots _rt
  _roots="$(command -v wt_all_roots >/dev/null 2>&1 && wt_all_roots || true)"; [ -n "$_roots" ] || _roots="$WORKTREES_ROOT"
  for wt in $(for _rt in $_roots; do printf '%s\n' "$_rt/${dir}__"* "$_rt/${repo_only}__"*; done); do
    [ -d "$wt" ] || continue
    br=$(git -C "$wt" symbolic-ref --short HEAD 2>/dev/null) || continue
    pr_line=$(printf '%s\n' "$merged" | awk -F'\t' -v b="$br" '$1==b{print $2; exit}')
    [ -n "$pr_line" ] || { info "   keep: $(basename "$wt") (branch '$br' has no merged PR)"; continue; }
    any=1
    teardown_one "$owner_repo" "$pr_line" "$wt"
  done
  [ "$any" = "0" ] && info "   nothing to tear down"
  return 0
}

# ---------------------------------------------------------------------------
case "${1:-}" in
  --sweep)
    [ $# -ge 2 ] || { err "usage: $0 --sweep <owner/repo>"; exit 1; }
    sweep_repo "$2"
    ;;
  --sweep-all)
    for r in ebda-store ebda-whatsapp ebda-studio \
             mypovonai digital-card ebda-store ebda-whatsapp ebda-studio ebda-foundation; do
      sweep_repo "$r"
    done
    ;;
  "" | -h | --help)
    sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
    ;;
  *)
    [ $# -ge 2 ] || { err "usage: $0 <owner/repo> <pr-number> [worktree-path]"; exit 1; }
    teardown_one "$1" "$2" "${3:-}"
    ;;
esac
