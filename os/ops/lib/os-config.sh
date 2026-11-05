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
#   OS_VM       the primary CI guest (first word of OS_UMBRA_VMS)
#   OS_BILLED_ORGS  OS_ORGS minus the personal account (billing / GHAS checks apply to orgs only)
# This file and os/config/os.env are the only places the identity literals may appear (os/tests/no-literal-config.test.sh).

os_config_load() {
  local _here _f _cand
  _here="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
  _f=""
  for _cand in "${OS_CONFIG_FILE:-}" "$_here/../../config/os.env" "$_here/../os.env" "$HOME/.claude/os.env"; do
    if [ -n "$_cand" ] && [ -f "$_cand" ]; then _f="$_cand"; break; fi
  done
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
  : "${OS_UMBRA_VMS:=fwb-ci6}"
  : "${OS_SENTRY_ORG:=org-lingering-river-25973882}"
  : "${OS_PERSONAL_OWNER:=voidengineer-911}"
  : "${OS_NEON_ORG:=org-lingering-river-25973882}"
  OS_ORG="${OS_ORGS%% *}"
  OS_BILLED_ORGS=""   # the orgs only (OS_ORGS minus the personal account): what billing and GHAS checks iterate
  for _o in $OS_ORGS; do [ "$_o" = "$OS_PERSONAL_OWNER" ] || OS_BILLED_ORGS="${OS_BILLED_ORGS:+$OS_BILLED_ORGS }$_o"; done
  OS_VM="${OS_UMBRA_VMS%% *}"
  set +a
  return 0
}
