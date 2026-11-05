# shellcheck shell=bash
# lib/trusted-origin.sh - the ONE definition of "a repo Ahmad owns", used by wt-deps.sh (hook mode), the global git
# hook dispatcher and install.sh (ebda.chainHusky opt-in). Fully anchored: exact host github.com, org in the allowlist,
# a single repo segment - so `https://evil.tld/github.com/Whisky-11/x`, `git@evil:github.com/$OS_ORG/x`,
# `https://github.com.evil.tld/Whisky-11/x`, userinfo and query tricks all FAIL.

# wt_trusted_origin_url <url>  -> 0 only for an exact github.com URL under one of the $OS_ORGS owners
# shellcheck source=os-config.sh
command -v os_config_load >/dev/null 2>&1 || . "$(dirname "${BASH_SOURCE[0]}")/os-config.sh" 2>/dev/null || true
[ -n "${OS_ORG:-}" ] || ! command -v os_config_load >/dev/null 2>&1 || os_config_load
wt_trusted_origin_url() {
  # The owner allowlist is $OS_ORGS (os/config/os.env); the default mirrors it so a bare `source` still works.
  local orgs alt re
  orgs="${OS_ORGS:-$OS_ORGS}"
  alt="$(printf '%s' "$orgs" | tr -s ' ' '|' | sed -e 's/^|//' -e 's/|$//' -e 's/\./\\./g')"
  re="^(https://github\\.com/|git@github\\.com:|ssh://git@github\\.com/)(${alt})/[A-Za-z0-9_][A-Za-z0-9._-]*(\\.git)?/?\$"
  [[ "${1:-}" =~ $re ]]
}

# wt_trusted_repo <dir>  -> 0 when origin is trusted AND the repo's resolved real path is under $OS_PROJECTS_DIR
# (WT_TRUST_ROOT overrides the root for tests). Works for the main checkout and any linked worktree.
wt_trusted_repo() {
  local d root url
  d="$(cd "${1:-.}" 2>/dev/null && pwd -P)" || return 1
  root="$(cd "${WT_TRUST_ROOT:-$OS_PROJECTS_DIR}" 2>/dev/null && pwd -P)" || return 1
  case "$d/" in "$root"/*) ;; *) return 1 ;; esac
  url="$(git -C "$d" config --get remote.origin.url 2>/dev/null)" || return 1
  wt_trusted_origin_url "$url"
}
