#!/usr/bin/env bash
# The OS identity lives in os/config/os.env (and its built-in mirror in ops/lib/os-config.sh); every other script reads it through
# os_config_load. Fails when a non-comment line in os/ops outside tests/fixtures/launchd templates/docs carries one of the literals.
# Exempt: ops/tests/, ops/lib/__tests__/ (fixtures), ops/launchd/ (plist templates: the label is the file name), *.md, pure comment
# lines, and ops/lib/os-config.sh itself.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
RE='com\.ebda\.os|Ebda-AI-Studio|Whisky-11|voidengineer-911|umbra-ci6|org-lingering-river-25973882|Desktop/projects'
hits=$(find os/ops -type f ! -path 'os/ops/tests/*' ! -path 'os/ops/lib/__tests__/*' ! -path 'os/ops/launchd/*' ! -name '*.md' ! -path 'os/ops/lib/os-config.sh' ! -name '*.pyc' \
  | LC_ALL=C sort | while IFS= read -r f; do
    grep -nE "$RE" "$f" 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*#' | sed "s|^|$f:|"
  done)
if [ -n "$hits" ]; then
  echo "FAIL: identity literals outside os.env / os-config.sh (use \$OS_* from os_config_load):"
  printf '%s\n' "$hits" | cut -c1-200
  echo "($(printf '%s\n' "$hits" | wc -l | tr -d ' ') hits)"
  exit 1
fi
echo "PASS: no identity literals outside os.env / os-config.sh"
