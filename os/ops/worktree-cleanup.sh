#!/usr/bin/env bash
# Tidy worktrees + merged branches across EVERY repo that has them, and park each
# root checkout back on its own default branch. SAFE: never removes a worktree with
# uncommitted changes, never removes a recently-touched worktree, never deletes an
# unmerged branch. Run anytime the trees feel messy (auto-fix/* pileup, stray
# worktrees, roots parked on random branches).
#
# 2026-09-23 — three defects, all measured on this machine:
#   1. REPOS was a HARDCODED list of four repos while SEVENTEEN had worktrees. The
#      thirteen others (ebda-foundation, client-repo, mypovonai,
#      quote-studio, …) were never cleaned, so their worktrees accumulated
#      indefinitely — ebda-foundation alone had 14. A cleanup tool that names
#      the things it cleans stops covering anything added afterwards, silently.
#      The repo set is now DISCOVERED: every git repo under $OS_PROJECTS_DIR
#      (plus one level of group folders) unioned with every repo named by an
#      existing worktree directory.
#   2. It assumed every repo's default branch is `main`. ebda-foundation uses
#      `master`, so every fetch/checkout/merge-base against origin/main failed for
#      it. The default branch is now read per repo from origin/HEAD.
#   3. It never removed a WORKTREE — only dead refs and merged branches. A worktree
#      whose branch had long since merged stayed forever, which is what produced
#      the pileup. Merged + clean + untouched-for-2h worktrees are now removed.
# shellcheck source=lib/os-config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/os-config.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-config.sh" 2>/dev/null || true
command -v os_config_load >/dev/null 2>&1 && os_config_load
set -uo pipefail
. "$(dirname "$0")/lib/os-state.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-state.sh" 2>/dev/null || true
. "$(dirname "$0")/lib/wt-safety.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/wt-safety.sh" 2>/dev/null || { echo "worktree-cleanup: lib/wt-safety.sh missing; refusing to reap without the safety checks" >&2; exit 2; }

# TCC canary (2026-07-12): abort when the launchd context cannot see ~/Desktop
OS_JOB_NAME=worktree-cleanup
if command -v require_projects_access >/dev/null 2>&1; then require_projects_access || exit 0; fi

PROJECTS="${PROJECTS_DIR:-$OS_PROJECTS_DIR}"
PROJECTS_ROOT="$PROJECTS"   # lib/projects-layout.sh reads this at call time
. "$(dirname "$0")/lib/wt-roots.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/wt-roots.sh" 2>/dev/null || true
WT_DIR="${WORKTREES_DIR:-$PROJECTS/_worktrees}"
# every root to scan: the explicit WORKTREES_DIR override alone (tests), else internal + SSD (missing roots skipped)
if [ -n "${WORKTREES_DIR:-}" ] || ! command -v wt_all_roots >/dev/null 2>&1; then WT_DIRS="$WT_DIR"; else WT_DIRS="$(wt_all_roots)"; fi
# A worktree touched more recently than this is assumed to belong to a live
# session and is left alone even when its branch has merged.
FRESH_MIN="${WORKTREE_FRESH_MIN:-120}"

# --- discover every repo root, rather than naming them ----------------------
# (a) every repo in a business-folder slot (lib/projects-layout.sh list_repo_roots)
# (b) repos named by an existing worktree dir: <repo>__<branch>
discover_roots() {
  { list_repo_roots
    while IFS= read -r _wd; do
      [ -n "$_wd" ] || continue
      for w in "$_wd"/*/; do
        [ -d "$w" ] || continue
        r="${w%/}"; r="${r##*/}"; r="${r%%__*}"
        resolve_repo_dir "$r" 2>/dev/null || true
      done
    done <<EOR
$WT_DIRS
EOR
  } | sort -u
}

default_branch() {  # origin/HEAD, else main, else master
  local root="$1" b
  b="$(git -C "$root" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)"
  b="${b#origin/}"
  if [ -z "$b" ]; then
    git -C "$root" show-ref -q --verify refs/remotes/origin/main && b=main
  fi
  if [ -z "$b" ]; then
    git -C "$root" show-ref -q --verify refs/remotes/origin/master && b=master
  fi
  printf '%s' "${b:-main}"
}

roots=(); while IFS= read -r r; do [ -n "$r" ] && roots+=("$r"); done < <(discover_roots)
# Positive control: an empty discovery means the layout moved or TCC is blind —
# report it instead of exiting 0 with "done." and cleaning nothing.
if [ "${#roots[@]}" -eq 0 ]; then
  echo "worktree-cleanup: discovered ZERO repos under $PROJECTS — nothing scanned (layout moved, or no access)" >&2
  exit 1
fi

n_repos=0; n_wt_removed=0; n_br_deleted=0; n_wt_live=0
# `${roots[@]+"${roots[@]}"}`, not a bare `"${roots[@]}"`: under `set -u` bash
# 3.2 (still the /bin/bash on macOS) treats an empty array's expansion as an
# unbound variable and aborts. The zero-repo case is already caught above, so
# this is the repo's standing array-expansion form rather than a live bug —
# `ops/lib/__tests__/empty-array-guard.test.sh` enforces it, and it caught this.
for ROOT in ${roots[@]+"${roots[@]}"}; do
  r="${ROOT##*/}"
  n_repos=$((n_repos + 1))
  DEF="$(default_branch "$ROOT")"
  echo "=== $r (default: $DEF) ==="
  git -C "$ROOT" worktree prune                 # drop dead worktree refs (dir gone)
  git -C "$ROOT" fetch origin "$DEF" -q || true

  # Park the ROOT checkout on its default branch (keeps untracked files).
  cur="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  if [ "$cur" != "$DEF" ]; then
    if [ -z "$(git -C "$ROOT" status --porcelain --untracked-files=no)" ]; then
      git -C "$ROOT" checkout -q "$DEF" && git -C "$ROOT" pull --ff-only -q origin "$DEF" 2>/dev/null && echo "  root: $cur -> $DEF"
    else
      echo "  root on '$cur' has TRACKED local changes — left as-is (commit/stash first)"
    fi
  else
    # already parked: STILL ff-pull — stale roots made docs-scan report a
    # DEPLOYMENT.md move as un-done 5 days after it merged (2026-07-12; store root
    # was 47 commits behind). Roots must track origin or every root-reading scan lies.
    if [ -z "$(git -C "$ROOT" status --porcelain --untracked-files=no)" ]; then
      git -C "$ROOT" pull --ff-only -q origin "$DEF" 2>/dev/null && echo "  root: $DEF freshened"
    fi
  fi

  # merged <branch>: in origin/<default> as an ancestor, OR (squash/rebase merges,
  # which rewrite history) a MERGED PR on GitHub whose head is this branch's exact
  # tip. The tip match is the safety: a branch that gained commits after its PR
  # merged is NOT merged, so unpushed work is never removed. No gh -> ancestor only.
  merged() {
    # A branch is merged when ALL its commits are in origin/<default> AND it has commits of its own (reflog). 0 commits
    # ahead with no commit of its own is a NEW branch (git worktree add -b x origin/main), not a merged one: that reaped
    # a brand-new worktree and its uncommitted plan on 2026-10-25. Otherwise a MERGED PR at this exact tip.
    git -C "$ROOT" merge-base --is-ancestor "$1" "origin/$DEF" 2>/dev/null && branch_has_own_commits "$ROOT" "$1" && return 0
    command -v "${HYGIENE_GH:-gh}" >/dev/null 2>&1 || return 1
    local tip heads
    tip="$(git -C "$ROOT" rev-parse "$1" 2>/dev/null)" || return 1
    heads="$(cd "$ROOT" && "${HYGIENE_GH:-gh}" pr list --head "$1" --state merged --json headRefOid --jq '.[].headRefOid' 2>/dev/null)" || return 1
    grep -qx "$tip" < <(printf '%s\n' "$heads") && return 0
    # G13: squash merge whose PR head moved after merge - content-identical to main counts as merged
    local slug; slug="$(git -C "$ROOT" remote get-url origin 2>/dev/null | sed -E 's#.*github.com[:/]##; s#\.git$##')"
    wt_squash_integrated "$ROOT" "$slug" "$1" "origin/$DEF" "$1"
  }

  # A LOCAL BRANCH (no worktree, no files) that is an ancestor of origin/<default> loses nothing when deleted, so
  # branch deletion keeps the ancestor rule; only WORKTREE removal needs the strict merged() above.
  branch_merged() {
    git -C "$ROOT" merge-base --is-ancestor "$1" "origin/$DEF" 2>/dev/null && return 0
    merged "$1"
  }

  # Remove worktrees whose branch is already merged AND that hold no work.
  # Three gates, all required: merged (ancestor, or squash-merged PR at this tip), no uncommitted
  # changes (tracked or untracked), and not touched in the last FRESH_MIN
  # minutes — a fresh worktree belongs to a session that is still using it.
  while IFS= read -r wt; do
    [ -n "$wt" ] || continue
    [ "$wt" = "$ROOT" ] && continue
    wb="$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    [ -z "$wb" ] || [ "$wb" = HEAD ] && continue
    case "$wb" in main|master|preview) continue;; esac
    merged "$wb" || continue
    if [ "$(wt_dirty_count "$wt")" != "0" ]; then
      echo "  kept (uncommitted changes): $wb"; continue
    fi
    if [ -n "$(find "$wt" -maxdepth 0 -mmin "-$FRESH_MIN" 2>/dev/null)" ]; then
      echo "  kept (touched < ${FRESH_MIN}m ago): $wb"; continue
    fi
    if git -C "$ROOT" worktree remove "$wt" 2>/dev/null; then
      echo "  removed merged worktree: $wb"; n_wt_removed=$((n_wt_removed + 1))
    fi
  done < <(git -C "$ROOT" worktree list --porcelain | awk '/^worktree /{print $2}')
  git -C "$ROOT" worktree prune

  # Delete LOCAL branches already merged into origin/<default> (skip the default
  # branch + preview + any branch still checked out in a worktree).
  active="$(git -C "$ROOT" worktree list --porcelain | awk '/^branch /{gsub("refs/heads/","",$2);print $2}')"
  while IFS= read -r b; do
    [ -z "$b" ] && continue
    case "$b" in "$DEF"|main|master|preview) continue;; esac
    grep -qx "$b" < <(printf '%s\n' "$active") && continue
    if branch_merged "$b"; then
      git -C "$ROOT" branch -D "$b" >/dev/null 2>&1 && { echo "  deleted merged branch: $b"; n_br_deleted=$((n_br_deleted + 1)); }
    fi
  done < <(git -C "$ROOT" branch --format='%(refname:short)')

  live="$(git -C "$ROOT" worktree list | grep -c .)"
  n_wt_live=$((n_wt_live + live))
  echo "  live worktrees: $live"
done
echo "done. scanned=$n_repos repos · worktrees removed=$n_wt_removed · branches deleted=$n_br_deleted · worktrees live=$n_wt_live"
