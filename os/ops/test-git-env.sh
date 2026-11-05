#!/usr/bin/env bash
# test-git-env.sh - a sanitised git environment for tests that run MUTATING git (init/commit/checkout/config/...).
#
# WHY (2026-10-25). A git hook (husky pre-push) exports GIT_DIR / GIT_WORK_TREE / GIT_INDEX_FILE into every child.
# A test that ran `git init` + commits + `checkout` in a mkdtemp dir inherited them; `cwd`/`git -C` do NOT win over
# GIT_DIR, so the test re-initialised the REAL repo and set core.bare=true for 20-40 min (root checkout: "this
# operation must be run in a work tree"; stray commits and branches; sibling tests then saw 0 tracked files).
# It is green when run by hand and only fails under the hook, so it must be impossible, not remembered.
#
# SOURCE it:   . "$HOME/.claude/scripts/test-git-env.sh"
#   clean_git_env                 unset every GIT_* var, GIT_CONFIG_GLOBAL=/dev/null, GIT_CONFIG_NOSYSTEM=1
#   sandbox_git_init <dir>        git init (clean env) + local identity, commit.gpgsign=false, then asserts the toplevel is <dir>
#   sandbox_git <dir> <args...>   run git in <dir> with a clean env; refuses unless <dir>'s toplevel IS <dir>
# or RUN it:    test-git-env.sh -- <command...>     (the command inherits a clean env)
# Node/other languages: spread `env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE ...` or run via the line above.
# Guard: ops/check-test-git-env.sh <dir> fails any test that spawns mutating git without this helper.

clean_git_env() {
  local v
  for v in $(env | sed -n 's/^\(GIT_[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$v"; done
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
}
_sandbox_assert() {  # $1=dir: its git toplevel must be itself (realpath-normalised)
  local want got
  want="$(cd "$1" 2>/dev/null && pwd -P)" || { echo "test-git-env: no such dir $1" >&2; return 1; }
  got="$(cd "$1" && env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git rev-parse --show-toplevel 2>/dev/null)" || got=""
  [ -n "$got" ] && got="$(cd "$got" && pwd -P)"
  [ "$got" = "$want" ] || { echo "test-git-env: REFUSING - $1 is not its own git toplevel (got '${got}')" >&2; return 1; }
}
sandbox_git_init() {
  [ -n "${1:-}" ] || { echo "sandbox_git_init <dir>" >&2; return 64; }
  ( clean_git_env; mkdir -p "$1" && cd "$1" && git init -q . && git config user.email t@example.invalid \
      && git config user.name test && git config commit.gpgsign false ) || return 1
  _sandbox_assert "$1"
}
sandbox_git() {
  local d="${1:-}"; [ -n "$d" ] || { echo "sandbox_git <dir> <args...>" >&2; return 64; }; shift
  _sandbox_assert "$d" || return 1
  ( clean_git_env; cd "$d" && git "$@" )
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then   # executed, not sourced
  if [ "${1:-}" = "--" ] && [ "$#" -gt 1 ]; then shift; clean_git_env; exec "$@"; fi
  echo "usage: . test-git-env.sh   |   test-git-env.sh -- <command...>" >&2; exit 64
fi
