#!/usr/bin/env bash
# ============================================================
# Ebda AI OS - restore-drill.sh   (weekly restore drill, runs on the Mac: ruling F-I6)
#
# The restore drill needs the R2 + age secrets that the hands container must not hold, so it runs HERE, weekly, and posts its
# result to the brain (POST $OS_BRAIN_URL/drill, Bearer $INGEST_TOKEN). The brain's dr-drill watcher only checks how stale the
# last PASS is: digest note after 8 days, one P1 message after 14. Nothing here messages anyone.
#
# The command comes from the per-machine file ~/.ebda-os.local.env (never git):
#     OS_RESTORE_DRILL_CMD="node /path/to/ebda-store/scripts/ops/restore-drill.mjs --target api"
# PASS = exit 0 AND the word PASS in the output AND no FAIL. Anything else posts FAIL. A command that is not configured exits 3
# (loud: a drill that never ran must not look like a drill that passed). The post failing exits 10 (the result is printed).
# DRY_RUN=1 prints what would run and posts nothing.
# ============================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/os-config.sh
. "$HERE/lib/os-config.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-config.sh" 2>/dev/null || true
command -v os_config_load >/dev/null 2>&1 && os_config_load
export PATH="$PATH:/opt/homebrew/bin:/usr/bin:/bin"
DRY_RUN="${DRY_RUN:-0}"
if [ -z "${OS_RESTORE_DRILL_CMD:-}" ]; then
  echo "[restore-drill] NOT CONFIGURED: set OS_RESTORE_DRILL_CMD in ~/.ebda-os.local.env. The drill did NOT run; this is not a pass." >&2
  exit 3
fi
if [ -f "${OS_SERVICES_ENV:-}" ]; then
  for _k in OS_BRAIN_URL INGEST_TOKEN; do
    [ -n "${!_k:-}" ] && continue
    _l="$(grep -E "^${_k}=" "$OS_SERVICES_ENV" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"'"'")"
    [ -n "$_l" ] && export "$_k=$_l"
  done
fi
if [ "$DRY_RUN" = 1 ]; then echo "[restore-drill] DRY: would run: $OS_RESTORE_DRILL_CMD ; then POST result to ${OS_BRAIN_URL:-<no brain url>}/drill"; exit 0; fi
out="$(mktemp)"; trap 'rm -f "$out"' EXIT
bash -c "$OS_RESTORE_DRILL_CMD" > "$out" 2>&1; rc=$?
result=fail
if [ "$rc" = 0 ] && grep -qw PASS "$out" && ! grep -qw FAIL "$out"; then result=pass; fi
note="$(tail -c 300 "$out" | tr '\n"\\' '  ' )"
echo "[restore-drill] exit $rc -> $result"
body="$(python3 -I -c 'import json,sys; print(json.dumps({"result": sys.argv[1], "note": sys.argv[2]}))' "$result" "$note")"
if [ -n "${OS_BRAIN_URL:-}" ] && [ -n "${INGEST_TOKEN:-}" ] \
   && curl -fsS -m 30 -o /dev/null -X POST "${OS_BRAIN_URL%/}/drill" -H "Authorization: Bearer $INGEST_TOKEN" -H 'content-type: application/json' --data-binary "$body"; then
  echo "[restore-drill] posted $result to the brain"
  exit 0
fi
echo "[restore-drill] could not post to the brain (OS_BRAIN_URL / INGEST_TOKEN unset or unreachable); result was: $result" >&2
exit 10
