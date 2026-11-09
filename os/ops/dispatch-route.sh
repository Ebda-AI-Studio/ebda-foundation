#!/usr/bin/env bash
# route <kind> <target-json> -> invoke the responder. Responder paths overridable for tests.
set -uo pipefail
HERE_R="$(cd "$(dirname "$0")" && pwd)"
_f() { printf '%s' "$2" | python3 -c 'import json,sys;print(json.load(sys.stdin).get(sys.argv[1],""))' "$1"; }
kind="$1"; t="$2"
case "$kind" in
  ci-failure)     AUTOFIX_ONLY_REPO="$(_f slug "$t")" bash "${ROUTE_AUTOFIX:-$HERE_R/auto-fix-check.sh}" ;;
  code-finding)   bash "${ROUTE_REMEDIATE:-$HERE_R/remediate.sh}" --only "$(_f id "$t")" ;;
  service-down)   bash "${ROUTE_HEAL:-$HERE_R/heal-watch.sh}" "$(_f name "$t")" ;;
  runner-offline) bash "${ROUTE_RUNNER:-$HERE_R/runner-restore.sh}" "$(_f name "$t")" ;;
esac
