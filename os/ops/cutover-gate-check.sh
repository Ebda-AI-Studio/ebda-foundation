#!/usr/bin/env bash
# cutover-gate-check.sh - the Task 7 cutover gate. Reads the old-job disposition table in os/MANIFEST.md and exits 1, listing:
#   - every old job (ops/launchd plist or launchd/unported-jobs.list) with no row
#   - every PORT-BRAIN row whose cloud/brain/src/watchers/<id>.ts does not exist
#   - every REPLACED-BY row whose named path under os/ does not exist
#   - every KEEP-MAC row not in launchd/mac-local.list (except the explicit pending-task-6 marker, which is listed as pending)
#   - every DROP row without a reason
#   - every PORT-BRAIN watcher that exists on disk but is not wired into the scheduler (cloud/brain/src/watchers/run.ts GROUPS)
# After the brain deploy, BEFORE the Mac jobs are booted out (I-10): --deployed <brain-url> reads GET /api/state (a Cloudflare
# Access service token in CF_ACCESS_CLIENT_ID / CF_ACCESS_CLIENT_SECRET, or --state-file F for a saved copy) and fails while any
# PORT-BRAIN id is listed under `unconfigured`: a watcher that only raises monitor-unconfigured has NOT replaced its Mac job.
# Usage: cutover-gate-check.sh [--root REPO_ROOT] [--deployed BRAIN_URL [--state-file F]]   (default root: the repo this script lives in)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
case "${1:-}" in -h|--help) sed -n 2,9p "${BASH_SOURCE[0]}" | sed "s/^# \{0,1\}//"; exit 0 ;; esac
DEPLOYED=""; STATE_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="$(cd "${2:?--root needs a directory}" && pwd)"; shift 2 ;;
    --deployed) DEPLOYED="${2:?--deployed needs the brain URL}"; shift 2 ;;
    --state-file) STATE_FILE="${2:?--state-file needs a file}"; shift 2 ;;
    *) echo "cutover-gate: unknown argument $1" >&2; exit 64 ;;
  esac
done
OSD="$ROOT/os"; MAN="$OSD/MANIFEST.md"
[ -f "$MAN" ] || { echo "cutover-gate: no $MAN" >&2; exit 2; }
bad=0; PORT_IDS=""
say() { echo "BLOCKED: $*"; bad=$((bad+1)); }
jobs="$( { for p in "$OSD"/ops/launchd/*.plist; do [ -f "$p" ] && basename "$p" .plist | sed 's/^com\.[a-z]*\.os\.//'; done
           grep -vE '^(#|[[:space:]]*$)' "$OSD/launchd/unported-jobs.list" 2>/dev/null; } | sort -u)"
table="$(awk -F'|' '/^## Old-job dispositions/{on=1;next} on && /^\| /{gsub(/^ +| +$/,"",$2);gsub(/^ +| +$/,"",$3);gsub(/^ +| +$/,"",$4);gsub(/^ +| +$/,"",$5);print $2"\t"$3"\t"$4"\t"$5}' "$MAN" | grep -vE '^(Job|---)')"
for j in $jobs; do
  grep -qxF "$j" < <(printf '%s\n' "$table" | cut -f1) || say "old job '$j' has no disposition row"
done
while IFS=$'\t' read -r job disp detail reason; do
  [ -n "$job" ] || continue
  case "$disp" in
    PORT-BRAIN)
      [ -f "$OSD/cloud/brain/src/watchers/$detail.ts" ] || say "$job: PORT-BRAIN watcher '$detail' missing (os/cloud/brain/src/watchers/$detail.ts)"
      # present on disk is not scheduled: run.ts must import it (GROUPS runs every imported watcher)
      if [ -f "$OSD/cloud/brain/src/watchers/$detail.ts" ] && [ -f "$OSD/cloud/brain/src/watchers/run.ts" ]; then
        grep -qF "from './$detail'" "$OSD/cloud/brain/src/watchers/run.ts" || say "$job: PORT-BRAIN watcher '$detail' exists but is not scheduled (not imported by watchers/run.ts)"
      fi
      PORT_IDS="$PORT_IDS $detail" ;;
    REPLACED-BY) [ -e "$OSD/$detail" ] || say "$job: REPLACED-BY target os/$detail does not exist" ;;
    KEEP-MAC)
      if [ "$detail" = pending-task-6 ]; then say "$job: KEEP-MAC but its script and launchd entry are not landed yet (Task 6)"
      elif ! grep -qxF "$detail" < <(cut -f1 "$OSD/launchd/mac-local.list"); then say "$job: KEEP-MAC but '$detail' is not in launchd/mac-local.list"; fi ;;
    DROP) { [ -n "$reason" ] && [ "$reason" != - ]; } || say "$job: DROP without a reason" ;;
    *) say "$job: unknown disposition '$disp'" ;;
  esac
done <<< "$table"
if [ -n "$DEPLOYED" ]; then
  if [ -z "$STATE_FILE" ]; then
    STATE_FILE="$(mktemp)"; trap 'rm -f "$STATE_FILE"' EXIT
    hdr=(); [ -n "${CF_ACCESS_CLIENT_ID:-}" ] && hdr=(-H "CF-Access-Client-Id: $CF_ACCESS_CLIENT_ID" -H "CF-Access-Client-Secret: ${CF_ACCESS_CLIENT_SECRET:-}")
    curl -fsS -m 30 ${hdr[@]+"${hdr[@]}"} "${DEPLOYED%/}/api/state" -o "$STATE_FILE" 2>/dev/null || say "deployed: could not read ${DEPLOYED%/}/api/state (Access service token set?)"
  fi
  if [ -s "$STATE_FILE" ]; then
    unconf="$(python3 -I -c 'import json,sys; print(" ".join(json.load(open(sys.argv[1])).get("unconfigured") or ["\x00NONE"]))' "$STATE_FILE" 2>/dev/null || echo "\x00BAD")"
    case "$unconf" in *BAD*) say "deployed: /api/state is not the brain's JSON" ;; esac
    for id in $PORT_IDS; do
      case " $unconf " in *" $id "*) say "deployed: watcher '$id' is running UNCONFIGURED on the brain (monitor-unconfigured); it has not replaced its Mac job" ;; esac
    done
  fi
fi
if [ "$bad" -gt 0 ]; then echo "cutover-gate: $bad blocker(s)"; exit 1; fi
echo "cutover-gate: clear"
