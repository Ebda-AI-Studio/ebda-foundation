#!/usr/bin/env bash
# git-hooks/dispatch.sh — the ONE global git hook, installed (by ops/install.sh) as every standard hook name
# under ~/.claude/git-hooks and activated with `git config --global core.hooksPath ~/.claude/git-hooks`.
#
# WHY (2026-10-25): wt-deps.sh (APFS-clone dependency cache, ~0.2 GB per worktree instead of ~2.3 GB) was only
# reached through new-task-worktree.sh. A raw `git worktree add`, Claude Code's EnterWorktree / Agent
# isolation:"worktree", Codex, or any other tool bypassed it and ran its own npm ci. A global post-checkout hook sees
# EVERY worktree creation no matter who ran git.
#
# Two jobs, in this order:
#   1. foundation logic. Only post-checkout does anything: a NEW linked worktree (previous HEAD all zeros AND
#      git-dir != git-common-dir; a clone never qualifies) gets `wt-deps.sh` in HOOK MODE (WT_DEPS_HOOK=1): only for
#      TRUSTED repos (origin in one of $OS_ORGS AND under $OS_PROJECTS_DIR), and a cache-miss
#      install runs with --ignore-scripts. Never fails the git command; WT_SKIP_DEPS=1 opts out; below the
#      WT_MIN_FREE_GB (30) floor it only CLONES from a cache hit - it never starts a fresh multi-GB install.
#   2. CHAIN to the repo's own LOCAL hook, because a global core.hooksPath REPLACES <repo>/.git/hooks:
#        <git-common-dir>/hooks/<name>        (plain repos, gitleaks, pre-push mirror ...)
#      exec'd, so stdin (pre-push, post-rewrite) and the exit code (pre-commit, commit-msg) pass straight through.
#      Husky is tracked repo content: chained only on explicit per-repo opt-in (see the SECURITY note below).
#
# KNOWN LIMIT (measured): a repo that sets its OWN core.hooksPath (husky v9 sets it to .husky/_) overrides the global
# one, so git never calls this file there. Those worktrees are covered by hooks/post-worktree-deps.sh (Claude
# Code) and wt-deps.sh re-arming husky itself.
# shellcheck source=lib/os-config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/os-config.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-config.sh" 2>/dev/null || true
command -v os_config_load >/dev/null 2>&1 && os_config_load
name="$(basename "$0")"

if [ "$name" = "post-checkout" ]; then
  prev="${1:-x}"
  zeros=0; case "$prev" in ''|*[!0]*) ;; *) zeros=1 ;; esac
  gd="$(git rev-parse --absolute-git-dir 2>/dev/null)"; cd_="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  if [ "$zeros" = 1 ] && [ -n "$gd" ] && [ "$gd" != "$cd_" ] && [ "${WT_SKIP_DEPS:-0}" != 1 ] && [ -z "${WT_DEPS_HOOK:-}" ]; then
    top="$(git rev-parse --show-toplevel 2>/dev/null)"
    WTD="${WT_DEPS_BIN:-$HOME/.claude/scripts/wt-deps.sh}"
    # trusted repos only (same validator as wt-deps hook mode + install.sh); anything else: do nothing at all
    # shellcheck source=/dev/null
    TRUSTLIB="${WT_TRUST_LIB:-$HOME/.claude/scripts/lib/trusted-origin.sh}"
    # shellcheck disable=SC1090
    if [ -n "$top" ] && [ -f "$top/package.json" ] && [ -x "$WTD" ] && [ -f "$TRUSTLIB" ] && . "$TRUSTLIB" && wt_trusted_repo "$top"; then
      # shellcheck disable=SC1090,SC1091
      . "$(dirname "$TRUSTLIB")/wt-roots.sh" 2>/dev/null || true
      # free space of the volume the worktree is on (SSD or internal), not always $HOME
      if command -v wt_free_kb >/dev/null 2>&1; then free_kb="$(wt_free_kb "$top")"; else free_kb="$(df -k "$HOME" | awk 'NR==2{print $4}')"; fi
      if [ "${free_kb:-0}" -ge $(( ${WT_MIN_FREE_GB:-30} * 1024 * 1024 )) ] || bash "$WTD" --check "$top" >/dev/null 2>&1; then
        mkdir -p "$HOME/Library/Logs" 2>/dev/null
        { echo "$(date -u +%FT%TZ) post-checkout new worktree $top"; WT_DEPS_HOOK=1 bash "$WTD" "$top" 2>&1; } \
          | tee -a "$HOME/Library/Logs/ebda-os-wt-deps-hook.log" >&2 || true
      else
        echo "wt-deps hook: host free < ${WT_MIN_FREE_GB:-30} GB and no cache hit - NOT installing deps in $top. Free disk first (workspace-hygiene.sh)." >&2
      fi
    fi
  fi
fi

# --- root-checkout guard (2026-11-23) ---
# Defect class (twice on 2026-11-23): `cd <worktree> && git merge ...` failed at the cd, so git ran in the ROOT checkout
# (~/Desktop/projects/<biz>/internal-projects/<repo> or <biz>/clients/<client>/<repo>), which must stay on main read-only,
# and moved local main ahead of origin. REFUSES (exit 1) pre-commit and pre-merge-commit when ALL hold: the checkout is
# the repo's MAIN worktree (git-dir == git-common-dir), it sits in a business-folder slot under $OS_PROJECTS_DIR, and
# HEAD is main/master. pre-merge-commit only runs when a merge CREATES a commit; a fast-forward (`git merge origin/main`,
# the legitimate way to keep root current) runs no pre-merge-commit and stays allowed. post-merge only WARNS afterwards
# (it fires for ff too and cannot undo), when root main ended up not contained in origin/main.
# Escape hatch: FORCEAI_ALLOW_ROOT_COMMIT=1 (every use is logged to ~/Library/Logs/root-commit-guard.log).
# Never blocks on what it cannot see (not a repo, detached HEAD, path outside the slots). See standard/worktree-process-hygiene.md s5.
root_checkout_is_guarded() {
  local gd cdir top proj br
  gd="$(git rev-parse --path-format=absolute --git-dir 2>/dev/null)" || return 1
  cdir="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  [ -n "$gd" ] && [ "$(cd "$gd" 2>/dev/null && pwd -P)" = "$(cd "$cdir" 2>/dev/null && pwd -P)" ] || return 1
  top="$(git rev-parse --show-toplevel 2>/dev/null)" || return 1
  [ -n "$top" ] || return 1
  top="$(cd "$top" 2>/dev/null && pwd -P)" || return 1
  proj="$(cd "${OS_PROJECTS_DIR:-$HOME/Desktop/projects}" 2>/dev/null && pwd -P)" || return 1
  case "$top" in
    "$proj"/*/internal-projects/*|"$proj"/*/clients/*/*) ;;
    *) return 1 ;;
  esac
  br="$(git symbolic-ref --short -q HEAD 2>/dev/null)" || return 1
  case "$br" in main|master) ;; *) return 1 ;; esac
  ROOT_GUARD_TOP="$top"; ROOT_GUARD_BRANCH="$br"
  return 0
}
case "$name" in
  pre-commit|pre-merge-commit)
    if root_checkout_is_guarded; then
      if [ "${FORCEAI_ALLOW_ROOT_COMMIT:-0}" = 1 ]; then
        mkdir -p "$HOME/Library/Logs" 2>/dev/null
        echo "$(date -u +%FT%TZ) $name ALLOWED via FORCEAI_ALLOW_ROOT_COMMIT=1 in $ROOT_GUARD_TOP ($ROOT_GUARD_BRANCH)" >> "$HOME/Library/Logs/root-commit-guard.log" 2>/dev/null || true
      else
        {
          echo "root-checkout-guard: REFUSED $name in $ROOT_GUARD_TOP (main checkout on $ROOT_GUARD_BRANCH)."
          echo "  Root checkouts stay on main, read-only. Do the work in a worktree:"
          echo "    ~/.claude/scripts/new-task-worktree.sh <repo> <feat|fix>/<task>"
          echo "  (a failed \`cd <worktree> && git ...\` runs git HERE - check the cd succeeded.)"
          echo "  Deliberate override: FORCEAI_ALLOW_ROOT_COMMIT=1 git ... (logged)."
        } >&2
        exit 1
      fi
    fi ;;
  post-merge)
    if root_checkout_is_guarded && [ "${FORCEAI_ALLOW_ROOT_COMMIT:-0}" != 1 ] \
       && git rev-parse -q --verify "refs/remotes/origin/$ROOT_GUARD_BRANCH" >/dev/null 2>&1 \
       && ! git merge-base --is-ancestor HEAD "refs/remotes/origin/$ROOT_GUARD_BRANCH" 2>/dev/null; then
      echo "root-checkout-guard: WARNING - local $ROOT_GUARD_BRANCH in $ROOT_GUARD_TOP is now AHEAD of origin/$ROOT_GUARD_BRANCH. Root must mirror origin: undo with \`git reset --hard origin/$ROOT_GUARD_BRANCH\` after checking nothing unique is on it, and redo the work in a worktree." >&2
    fi ;;
esac

# --- chain to the repo's own hook (exec: keeps stdin + exit status) ---
# SECURITY (2026-10-25 review): this file runs for EVERY repo on the machine, including a freshly cloned UNTRUSTED
# one, so it must never execute anything that arrives inside a repo checkout.
#   - default chain target: <git-common-dir>/hooks/<name> ONLY - that directory is local state, never cloned.
#   - husky (.husky/_/<name>, .husky/<name>) is tracked repo content, so it runs ONLY for a repo that Ahmad's own
#     setup opted in: `git config --local "$OS_GIT_CHAIN_KEY" true` (default ebda.chainHusky) (ops/install.sh sets it for his repos).
#   - the repo's node_modules/.bin is NEVER put on PATH here.
self="$(cd "$(dirname "$0")" && pwd -P)"
gcd="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
if [ -n "$gcd" ] && [ -x "$gcd/hooks/$name" ]; then
  h="$(cd "$gcd/hooks" && pwd -P)"; [ "$h" != "$self" ] && exec "$gcd/hooks/$name" "$@"
fi
if [ "$(git config --local --get "${OS_GIT_CHAIN_KEY:-ebda.chainHusky}" 2>/dev/null)" = "true" ] && [ "${HUSKY:-1}" != 0 ]; then
  top="$(git rev-parse --show-toplevel 2>/dev/null)"
  if [ -n "$top" ]; then
    if [ -x "$top/.husky/_/$name" ]; then exec "$top/.husky/_/$name" "$@"; fi
    if [ -f "$top/.husky/$name" ]; then exec sh -e "$top/.husky/$name" "$@"; fi
  fi
fi
exit 0
