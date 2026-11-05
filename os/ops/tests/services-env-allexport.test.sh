#!/usr/bin/env bash
# Class guard (#197): sourcing ~/.whisky-services.env WITHOUT `set -a` leaves the
# keys shell-local, so child processes (neonctl, node, ...) never see them. Every
# ops script that sources the env file must do so inside `set -a ... set +a`.
set -uo pipefail
cd "$(dirname "$0")/.."; OPS="$(pwd)"
_pass=0; _fail=0
scan() {   # files... -> offending lines
  grep -nE '^[[:space:]]*(\[ -f [^]]+\] && )?(\.|source) +"?\$(SVC_ENV|\{SVC_ENV\}|\{OS_SERVICES_ENV:-\$HOME/\.whisky-services\.env\}|HOME/\.whisky-services\.env)"?' "$@" 2>/dev/null \
    | grep -v 'set -a' || true
}
bad="$(scan "$OPS"/*.sh)"
if [ -z "$bad" ]; then echo "PASS: every ops script sources the services env under set -a"; _pass=1
else echo "FAIL: sourced without set -a:"; echo "$bad"; _fail=1; fi
# the scan must be able to see an offender (negative control)
T="$(mktemp -d)"; echo '[ -f "${OS_SERVICES_ENV:-$HOME/.whisky-services.env}" ] && . "${OS_SERVICES_ENV:-$HOME/.whisky-services.env}" 2>/dev/null || true' > "$T/x.sh"
[ -n "$(scan "$T/x.sh")" ] && { echo "PASS: negative control - a bare source is flagged"; _pass=$((_pass+1)); } || { echo "FAIL: scan is blind to a bare source"; _fail=$((_fail+1)); }
rm -rf "$T"
echo "services-env-allexport.test: $_pass passed, $_fail failed"; [ "$_fail" -eq 0 ]
