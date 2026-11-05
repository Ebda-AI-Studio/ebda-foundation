# shellcheck shell=bash
# lib/os-config.sh - the ONE loader for the OS identity (repo slug, orgs, launchd prefix, state dir, ...).
#
#   . "$(dirname "$0")/lib/os-config.sh" && os_config_load
#
# os_config_load sources, in order:
#   1. os/config/os.env      (repo defaults; found next to the repo, or at $OS_CONFIG_FILE, or ~/.claude/os.env once installed)
#   2. ~/.ebda-os.local.env  (per-machine overrides, never in git; path overridable with EBDA_OS_LOCAL_ENV)
# and exports every variable they define. Calling it twice is harmless. Returns 1 (and prints why) when no os.env exists,
# so a script can fail loudly at boot instead of running with an empty identity.

os_config_load() {
  local _here _f _cand
  _here="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
  _f=""
  for _cand in "${OS_CONFIG_FILE:-}" "$_here/../../config/os.env" "$_here/../os.env" "$HOME/.claude/os.env"; do
    if [ -n "$_cand" ] && [ -f "$_cand" ]; then _f="$_cand"; break; fi
  done
  if [ -z "$_f" ]; then
    echo "os-config: no os.env found (looked in \$OS_CONFIG_FILE, the repo's os/config/, ~/.claude/os.env)" >&2
    return 1
  fi
  set -a
  # shellcheck source=/dev/null
  . "$_f"
  _f="${EBDA_OS_LOCAL_ENV:-$HOME/.ebda-os.local.env}"
  # shellcheck source=/dev/null
  [ -f "$_f" ] && . "$_f"
  set +a
  return 0
}
