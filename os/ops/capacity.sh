#!/usr/bin/env bash
# Ebda AI OS - capacity.sh (register OS-C1): is there room to run more CI, measured from the GitHub API and the host disk.
#
#   capacity.sh [--repo OWNER/NAME]... [--run-limit N] [--starve-min M] [--quiet]
#
# CI now runs on GitHub-hosted ubuntu-24.04 (repo vars EBDA_*RUNS_ON) under the Free plan's ~20 concurrent jobs; the Mac runners are
# not the CI. So capacity is "how full is the hosted queue", per repo, read live:
#   in_progress = workflow runs in progress   queued = workflow runs waiting   oldest = age (min) of the oldest queued run
#   ci          = hosted | self-hosted | unset  (from repo variable EBDA_RUNS_ON; unset = workflows fall back to the Mac label)
#   runners     = online/total self-hosted runners registered on the repo (informational: offline is fine while ci=hosted)
# Verdict per repo (first match):
#   UNKNOWN    a read failed or was unparseable. FAIL CLOSED: callers must treat it as busy, never as free
#   STARVED    the oldest queued run waited longer than --starve-min (default 20)
#   SATURATED  in_progress >= --run-limit (default $CAPACITY_RUN_LIMIT or 20: workflow RUNS, a lower bound of concurrent JOBS)
#   BUSY       in_progress >= 75% of the limit, or anything queued
#   OK
# Host disk (free GB of $HOME's volume): green >= 45, amber >= 35, low >= 30, critical < 30, UNKNOWN when df is unreadable (never "999").
# Report only: this script deletes nothing. Writes $OS_STATE_DIR/capacity/status.tsv (repo, verdict, ...).
# Exit: 0 every repo OK/BUSY, 1 any SATURATED/STARVED, 2 any UNKNOWN (and none worse).
# Test seams: `gh` and `df` from PATH, OS_STATE_DIR, CAPACITY_REPOS (space separated default repos).
# shellcheck source=lib/os-config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/os-config.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-config.sh" 2>/dev/null || true
command -v os_config_load >/dev/null 2>&1 && os_config_load
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/args.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/args.sh" 2>/dev/null || true
. "$HERE/lib/os-state.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-state.sh" 2>/dev/null || true
command -v _ut >/dev/null 2>&1 || _ut() { shift; "$@"; }
command -v args_help >/dev/null 2>&1 && args_help "$0" "$@"
GH_TIMEOUT="${GH_TIMEOUT:-45}"
RUN_LIMIT="${CAPACITY_RUN_LIMIT:-20}"; STARVE_MIN=20; QUIET=0; repos=()
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repos+=("${2:?--repo needs OWNER/NAME}"); shift 2 ;;
    --run-limit) RUN_LIMIT="${2:?}"; shift 2 ;;
    --starve-min) STARVE_MIN="${2:?}"; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    *) echo "capacity.sh: unknown argument '$1' (try --help)" >&2; exit 2 ;;
  esac
done
case "$RUN_LIMIT$STARVE_MIN" in *[!0-9]*|"") echo "capacity.sh: --run-limit/--starve-min must be integers" >&2; exit 2 ;; esac
if [ "${#repos[@]}" -eq 0 ]; then
  # shellcheck disable=SC2206
  repos=(${CAPACITY_REPOS:-${OS_REPO_SLUG:-}})
fi
[ "${#repos[@]}" -gt 0 ] || { echo "capacity.sh: no repo (pass --repo or set CAPACITY_REPOS / OS_REPO_SLUG)" >&2; exit 2; }
ghx() { _ut "$GH_TIMEOUT" gh "$@"; }

# runs_stat <json> -> "<total_count> <oldest-age-minutes|->" ; unparseable -> exit 1
runs_stat() {
  python3 -I -c '
import sys, json, datetime
try:
    d = json.load(sys.stdin)
    n = int(d["total_count"])
    runs = d.get("workflow_runs") or []
except Exception:
    sys.exit(1)
age = "-"
ts = [r.get("created_at") for r in runs if r.get("created_at")]
if ts:
    t = min(datetime.datetime.strptime(x, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc) for x in ts)
    age = str(max(0, int((datetime.datetime.now(datetime.timezone.utc) - t).total_seconds() // 60)))
print(n, age)
'
}

worst=0; rows=""
for repo in ${repos[@]+"${repos[@]}"}; do
  verdict=UNKNOWN; inp="?"; q="?"; oldest="-"; ci="?"; rn="?"
  if ip_json="$(ghx api "repos/$repo/actions/runs?status=in_progress&per_page=100" 2>/dev/null)" \
     && q_json="$(ghx api "repos/$repo/actions/runs?status=queued&per_page=100" 2>/dev/null)" \
     && ip_s="$(printf '%s' "$ip_json" | runs_stat)" && q_s="$(printf '%s' "$q_json" | runs_stat)"; then
    inp="${ip_s%% *}"; q="${q_s%% *}"; oldest="${q_s##* }"
    verdict=OK
    [ "$q" -gt 0 ] && verdict=BUSY
    [ $((inp * 4)) -ge $((RUN_LIMIT * 3)) ] && verdict=BUSY
    [ "$inp" -ge "$RUN_LIMIT" ] && verdict=SATURATED
    if [ "$oldest" != "-" ] && [ "$oldest" -gt "$STARVE_MIN" ]; then verdict=STARVED; fi
  fi
  if v="$(ghx api "repos/$repo/actions/variables/EBDA_RUNS_ON" --jq .value 2>/dev/null)"; then
    case "$v" in *ubuntu*|*github*) ci=hosted ;; *) ci=self-hosted ;; esac
  else ci="unset"; fi
  if rj="$(ghx api "repos/$repo/actions/runners" 2>/dev/null)"; then
    rn="$(printf '%s' "$rj" | python3 -I -c 'import sys,json
try:
    r=json.load(sys.stdin).get("runners",[])
except Exception:
    print("?"); sys.exit(0)
print("%d/%d" % (len([x for x in r if x.get("status")=="online"]), len(r)))')"
  fi
  rows="$rows$repo	$verdict	in_progress=$inp	queued=$q	oldest_queued_min=$oldest	ci=$ci	runners_online=$rn
"
  case "$verdict" in
    SATURATED|STARVED) worst=1 ;;
    UNKNOWN) [ "$worst" -eq 1 ] || worst=2 ;;
  esac
done

# host disk: UNKNOWN on an unreadable df (a failed read must never look like free space)
free_gb=""; disk=UNKNOWN
if line="$(df -Pk "${HOME:-/}" 2>/dev/null | awk 'NR==2 {print $4}')" && [ -n "$line" ] && [ "$line" -ge 0 ] 2>/dev/null; then
  free_gb=$((line / 1048576))
  if [ "$free_gb" -ge 45 ]; then disk=green; elif [ "$free_gb" -ge 35 ]; then disk=amber; elif [ "$free_gb" -ge 30 ]; then disk=low; else disk=critical; fi
fi
[ "$disk" = UNKNOWN ] && [ "$worst" -eq 0 ] && worst=2

sd="${OS_STATE_DIR:-$HOME/.whisky-os-state}/capacity"
if mkdir -p "$sd" 2>/dev/null; then
  { printf '%s' "$rows"; printf 'host-disk\t%s\tfree_gb=%s\n' "$disk" "${free_gb:-?}"; } > "$sd/status.tsv.tmp" 2>/dev/null && mv "$sd/status.tsv.tmp" "$sd/status.tsv"
fi
if [ "$QUIET" -eq 0 ]; then
  printf '%s' "$rows"
  printf 'host-disk\t%s\tfree_gb=%s\n' "$disk" "${free_gb:-?}"
fi
exit "$worst"
