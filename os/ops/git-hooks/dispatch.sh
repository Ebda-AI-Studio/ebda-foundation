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
      free_kb="$(df -k "$HOME" | awk 'NR==2{print $4}')"
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
