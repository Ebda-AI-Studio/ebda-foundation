#!/usr/bin/env bash
# Isolated worktree per session/task — so concurrent Claude sessions never fight
# over a repo's ROOT checkout (the cause of branch collisions + stray commits).
#
# RULE: the repo root checkout stays on `main` and is never worked in. ALL active
# work happens in a per-task worktree created by this script.
#
# Usage: new-task-worktree.sh <repo-name> <branch>
#   new-task-worktree.sh ebda-store feat/mfa
#   new-task-worktree.sh ebda-whatsapp fix/native-cart
# shellcheck source=lib/os-config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/os-config.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-config.sh" 2>/dev/null || true
command -v os_config_load >/dev/null 2>&1 && os_config_load
set -euo pipefail

REPO="${1:?repo dir name under $OS_PROJECTS_DIR, e.g. ebda-store}"
BRANCH="${2:?branch name, e.g. feat/mfa or fix/foo}"
# Resolve the repo through the ONE layout definition (lib/projects-layout.sh):
# business-folder slots first (2026-09-25), legacy compat paths last.
# shellcheck source=/dev/null
. "$(dirname "$0")/lib/projects-layout.sh"
ROOT="$(resolve_repo_dir "$REPO" || echo "$OS_PROJECTS_DIR/$REPO")"

# Session awareness (2026-07-12): warn when OTHER live Claude sessions are
# already working in this repo's tree — the collision class behind stray
# commits + stash conflicts. Advisory only, never blocks.
if [ -x "$HOME/.claude/scripts/sessions-live.sh" ]; then
  others=$(bash "$HOME/.claude/scripts/sessions-live.sh" 2>/dev/null | grep -F "$REPO" || true)
  [ -n "$others" ] && printf '⚠️  other live session(s) in %s:\n%s\n' "$REPO" "$others"
fi
[ -d "$ROOT/.git" ] || { echo "ERROR: no git repo at $ROOT"; exit 1; }

# Disk guard (2026-10-24): a full host disk fails CI runner jobs and degrades the Mac (the native runners share this disk).
# Refuse to add another worktree under WT_MIN_FREE_GB (default 30) free. WT_FORCE=1 overrides.
MIN_FREE_GB="${WT_MIN_FREE_GB:-30}"
free_kb="$(df -k "$HOME" | awk 'NR==2{print $4}')"
if [ "${WT_FORCE:-0}" != "1" ] && [ "${free_kb:-0}" -lt $((MIN_FREE_GB*1024*1024)) ]; then
  printf 'REFUSING: host has %s GB free (< %s GB). A full disk fails CI runner jobs and degrades the Mac.\n' "$((free_kb/1024/1024))" "$MIN_FREE_GB" >&2
  # NO du scan here. `du -sk` over _worktrees/_backups/caches took 5+ MINUTES on a loaded host (2026-10-25) and ran on
  # EVERY refused call, adding disk I/O at exactly the moment the host was starved. The floor check needs only df.
  # The per-directory breakdown is opt-in: WT_REPORT=1, or run ops/worktree-report.sh.
  if [ "${WT_REPORT:-0}" = "1" ]; then
    echo "Top space users:" >&2
    du -sk "$OS_PROJECTS_DIR/_worktrees" "$OS_PROJECTS_DIR/_backups" "$HOME/.cache" "$HOME/Library/Caches" 2>/dev/null \
      | sort -rn | awk '{printf "  %6.1f GB  %s\n",$1/1048576,$2}' >&2
    echo "  largest worktrees:" >&2
    find "$OS_PROJECTS_DIR/_worktrees" -mindepth 1 -maxdepth 6 -type d -name '*__*' -prune -exec du -sk {} + 2>/dev/null \
      | sort -rn | head -8 | awk '{printf "  %6.1f GB  %s\n",$1/1048576,$2}' >&2
  else
    echo "  (space breakdown skipped: it is slow on a busy host. WT_REPORT=1 $0 $* , or bash ~/.claude/scripts/worktree-report.sh)" >&2
  fi
  echo "Cleanup: bash ~/.claude/scripts/workspace-hygiene.sh   (removes merged trees + node_modules of merged PRs; never one in use)" >&2
  echo "Override once: WT_FORCE=1 $0 $*" >&2
  exit 3
fi

SLUG="$(printf '%s' "$BRANCH" | tr '/' '-')"
WT="$OS_PROJECTS_DIR/_worktrees/${REPO}__${SLUG}"

git -C "$ROOT" fetch origin -q
# Detect the repo's actual default branch — foundation is 'master', most are 'main';
# don't hardcode (2026-07-22: hardcoded 'main' errored on every master-default repo).
DEF="$(git -C "$ROOT" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')"
[ -z "$DEF" ] && DEF="$(git -C "$ROOT" remote show origin 2>/dev/null | sed -n 's/.*HEAD branch: //p' | head -1)"
if [ -z "$DEF" ]; then for b in main master; do git -C "$ROOT" show-ref --verify --quiet "refs/remotes/origin/$b" && { DEF="$b"; break; }; done; fi
[ -z "$DEF" ] && DEF="main"
if git -C "$ROOT" worktree list --porcelain | grep -qx "worktree $WT"; then
  echo "already exists: $WT"; exit 0
fi
# Reuse the branch if it already exists (e.g. resuming), else create off fresh default.
if git -C "$ROOT" show-ref --verify --quiet "refs/heads/$BRANCH"; then
  git -C "$ROOT" worktree add "$WT" "$BRANCH"
else
  git -C "$ROOT" worktree add "$WT" -b "$BRANCH" "origin/$DEF"
  # Empty start commit (2026-10-25): a brand-new branch sits at origin/$DEF, 0 commits ahead - indistinguishable from
  # "fully merged" by ancestry alone, so the post-merge sweep deleted a fresh worktree and its uncommitted plan.
  # One commit ahead makes it unmistakably live. Conventional message so commitlint hooks accept it; never fatal.
  git -C "$WT" commit -q --allow-empty -m "chore: start $BRANCH" \
    || echo "WARN: could not make the empty start commit in $WT - make one by hand: git commit --allow-empty -m 'chore: start $BRANCH'" >&2
fi
# Deps via the shared APFS-clone cache (near-zero disk). Non-fatal; WT_SKIP_DEPS=1 to skip.
if [ "${WT_SKIP_DEPS:-0}" != "1" ] && [ -f "$WT/package.json" ] && [ -x "$(dirname "$0")/wt-deps.sh" ]; then
  bash "$(dirname "$0")/wt-deps.sh" "$WT" || echo "WARN: wt-deps failed - run: wt-deps.sh $WT" >&2
fi
echo "✅ worktree: $WT"
echo "   branch:   $BRANCH (off origin/$DEF)"
echo "   work HERE; never touch $ROOT (it stays on main). When done: PR, then run worktree-cleanup.sh."
