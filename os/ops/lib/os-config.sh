# shellcheck shell=bash
# lib/os-config.sh - the ONE loader for the OS identity (repo slug, orgs, launchd prefix, state dir, CI VMs, ...).
#
#   . "$(dirname "$0")/lib/os-config.sh" && os_config_load
#
# os_config_load sources, in order:
#   1. os/config/os.env      (repo defaults; found next to the repo, or at $OS_CONFIG_FILE, or ~/.claude/os.env once installed)
#   2. ~/.ebda-os.local.env  (per-machine overrides, never in git; path overridable with EBDA_OS_LOCAL_ENV)
#   3. built-in defaults for any key still unset (identical to os.env; os/tests/os-config-parity.test.sh keeps them equal),
#      so a script copied somewhere os.env is not reachable still gets the same identity instead of an empty one.
# It exports every key and the derived values:
#   OS_ORG      the primary org (first word of OS_ORGS)
#   OS_BILLED_ORGS  OS_ORGS minus the personal account (billing / GHAS checks apply to orgs only)
# This file and os/config/os.env are the only places the identity literals may appear (os/tests/no-literal-config.test.sh).

os_config_load() {
  local _here _f _cand
  _here="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
  _f=""
  for _cand in "${OS_CONFIG_FILE:-}" "$_here/../../config/os.env" "$_here/../os.env" "$HOME/.claude/os.env"; do
    if [ -n "$_cand" ] && [ -f "$_cand" ]; then _f="$_cand"; break; fi
  done
  local _allexport=0
  case $- in *a*) _allexport=1 ;; esac
  set -a
  # shellcheck source=/dev/null
  [ -n "$_f" ] && . "$_f"
  _f="${EBDA_OS_LOCAL_ENV:-$HOME/.ebda-os.local.env}"
  # shellcheck source=/dev/null
  [ -f "$_f" ] && . "$_f"
  : "${OS_PROJECTS_DIR:=$HOME/Desktop/projects}"
  : "${OS_HOME:=$OS_PROJECTS_DIR/Ebda-AI-Studio/internal-projects/ebda-foundation}"
  : "${OS_REPO_SLUG:=Ebda-AI-Studio/ebda-foundation}"
  : "${OS_ORGS:=Ebda-AI-Studio Whisky-11 voidengineer-911}"
  : "${OS_LAUNCHD_PREFIX:=com.ebda.os}"
  : "${OS_GIT_CHAIN_KEY:=ebda.chainHusky}"
  : "${OS_STATE_DIR:=$HOME/.whisky-os-state}"
  : "${OS_SERVICES_ENV:=$HOME/.whisky-services.env}"
  : "${OS_SENTRY_ORG:=org-lingering-river-25973882}"
  : "${OS_PERSONAL_OWNER:=voidengineer-911}"
  : "${OS_NONFORCE_BUSINESS_DIRS:=Ebda-AI-Studio Whisky-11 Personal}"
  OS_ORG="${OS_ORGS%% *}"
  OS_BILLED_ORGS=""   # the orgs only (OS_ORGS minus the personal account): what billing and GHAS checks iterate
  for _o in $OS_ORGS; do [ "$_o" = "$OS_PERSONAL_OWNER" ] || OS_BILLED_ORGS="${OS_BILLED_ORGS:+$OS_BILLED_ORGS }$_o"; done
  [ "$_allexport" = 1 ] || set +a
  return 0
}

# os_local_list <key> [default...] - print the string items of a list in the per-machine, gitignored
# ~/.ebda-os.local.json (path overridable with EBDA_OS_LOCAL_JSON), one per line. Client repo names, client
# domains and similar per-machine lists live there, never in git (see os/config/local.example.json).
# File absent or key missing -> prints the given defaults (if any), logs ONE line to stderr, returns 0.
os_local_list() {
  local _key="${1:?os_local_list needs a key}"; shift
  local _f="${EBDA_OS_LOCAL_JSON:-$HOME/.ebda-os.local.json}" _out="" _d
  if [ -f "$_f" ] && command -v python3 >/dev/null 2>&1; then
    _out="$(python3 -I - "$_f" "$_key" <<'PY' 2>/dev/null
import json, sys
try:
    v = json.load(open(sys.argv[1], encoding="utf-8")).get(sys.argv[2], [])
except Exception:
    sys.exit(0)
for x in v if isinstance(v, list) else []:
    if isinstance(x, str) and x.strip():
        print(x.strip())
PY
)"
  fi
  if [ -n "$_out" ]; then printf '%s\n' "$_out"; return 0; fi
  if [ "$#" -gt 0 ]; then for _d in "$@"; do printf '%s\n' "$_d"; done; return 0; fi
  echo "os-config: no '$_key' list in $_f (copy os/config/local.example.json there to enable); skipping" >&2
  return 0
}
