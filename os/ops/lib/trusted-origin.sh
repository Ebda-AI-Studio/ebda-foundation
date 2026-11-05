# shellcheck shell=bash
# lib/trusted-origin.sh - the ONE definition of "a repo Ahmad owns", used by wt-deps.sh (hook mode), the global git
# hook dispatcher and install.sh (ebda.chainHusky opt-in). Fully anchored: exact host github.com, org in the allowlist,
# a single repo segment - so `https://evil.tld/github.com/Whisky-11/x`, `git@evil:github.com/Ebda-AI-Studio/x`,
# `https://github.com.evil.tld/Whisky-11/x`, userinfo and query tricks all FAIL.

# wt_trusted_origin_url <url>  -> 0 only for an exact github.com URL under one of the $OS_ORGS owners
wt_trusted_origin_url() {
  # The owner allowlist is $OS_ORGS (os/config/os.env); the default mirrors it so a bare `source` still works.
  local orgs alt re
  orgs="${OS_ORGS:-Ebda-AI-Studio Whisky-11 voidengineer-911}"
  alt="$(printf '%s' "$orgs" | tr -s ' ' '|' | sed -e 's/^|//' -e 's/|$//' -e 's/\./\\./g')"
  re="^(https://github\\.com/|git@github\\.com:|ssh://git@github\\.com/)(${alt})/[A-Za-z0-9_][A-Za-z0-9._-]*(\\.git)?/?\$"
  [[ "${1:-}" =~ $re ]]
}

# wt_trusted_repo <dir>  -> 0 when origin is trusted AND the repo's resolved real path is under ~/Desktop/projects
# (WT_TRUST_ROOT overrides the root for tests). Works for the main checkout and any linked worktree.
wt_trusted_repo() {
  local d root url
  d="$(cd "${1:-.}" 2>/dev/null && pwd -P)" || return 1
  root="$(cd "${WT_TRUST_ROOT:-$HOME/Desktop/projects}" 2>/dev/null && pwd -P)" || return 1
  case "$d/" in "$root"/*) ;; *) return 1 ;; esac
  url="$(git -C "$d" config --get remote.origin.url 2>/dev/null)" || return 1
  wt_trusted_origin_url "$url"
}
