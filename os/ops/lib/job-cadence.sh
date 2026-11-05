#!/usr/bin/env bash
# Expected-cadence lookup for launchd jobs, for staleness decisions.
#
# 2026-08-25: heal-watch's os-heal block treated ANY status file older than a
# flat 3h as a silently-stopped subsystem and kickstarted its job. Every job on
# a CALENDAR schedule is legitimately older than that between runs, so the
# heuristic re-ran them forever:
#
#   code-health  weekly (Fri 06:00)  -> kickstarted 117 times
#   docs-scan    weekly (Sun 09:30)  -> 126 times
#   os-selftest  daily  (07:30)      -> 119 times
#   cost-guard   daily  (09:00)      -> 116 times
#
# code-health is the heavy `claude -p --model sonnet` audit over seven repos.
# A weekly job ran every ~3h11m (its 3h staleness window plus its own ~11min
# runtime), burning tokens and firing a Telegram digest each time — which is
# how a "weekly" audit produced six notifications in one day.
#
# A status file older than N is only evidence of breakage relative to how often
# the job was ever SUPPOSED to run. Ask the job's own plist, don't assume.
#
# Parsing goes through python3 + plistlib, NOT plutil: plutil is macOS-only, so
# a plutil implementation returned "unknown" for every job under Linux CI and
# the suite could only ever have been green by never running. plistlib also
# reads BINARY plists, which plutil string-matching could not.

# job_period_seconds <job> [launchagents_dir]
#   -> expected seconds between runs, or "" when it cannot be determined.
#
# StartInterval wins when both keys are present (launchd honours both; the
# shorter cadence is the one that governs freshness).
# StartCalendarInterval granularity comes from the COARSEST key present:
#   Weekday/Month/Day -> weekly-or-rarer, Hour -> daily, Minute only -> hourly.
# An ARRAY of calendar entries fires once per entry, so the period is divided
# by the number of entries — 4 daily entries is a 6-hourly job, not a daily one.
job_period_seconds() {
  local job="${1-}" dir="${2:-$HOME/Library/LaunchAgents}"
  [ -n "$job" ] || { echo ""; return 0; }
  local plist="$dir/com.ebda.os.$job.plist"
  [ -f "$plist" ] || { echo ""; return 0; }
  python3 - "$plist" <<'PY' 2>/dev/null || echo ""
import plistlib, sys

def granularity(d):
    if not isinstance(d, dict):
        return None
    # Coarsest key wins: a Weekday entry fires once a week no matter what
    # Hour/Minute sit beside it.
    for key, period in (("Month", 31536000), ("Weekday", 604800), ("Day", 2592000)):
        if key in d:
            return period
    if "Hour" in d:
        return 86400
    if "Minute" in d:
        return 3600
    return None

try:
    with open(sys.argv[1], "rb") as fh:
        pl = plistlib.load(fh)
except Exception:
    sys.exit(1)

iv = pl.get("StartInterval")
if isinstance(iv, int) and not isinstance(iv, bool) and iv > 0:
    print(iv); raise SystemExit(0)

cal = pl.get("StartCalendarInterval")
if isinstance(cal, dict):
    g = granularity(cal)
    if g: print(g)
elif isinstance(cal, list):
    gs = [granularity(e) for e in cal]
    gs = [g for g in gs if g]
    # Mixed granularities: the coarsest bounds how long a gap can legitimately
    # be, so take the max and divide by how many entries share it.
    if gs:
        coarsest = max(gs)
        n = sum(1 for g in gs if g == coarsest)
        print(max(1, coarsest // n))
PY
}

# job_stale_after <period_seconds> [floor_seconds]
#   -> the age past which a status file counts as evidence the job stopped.
#
# Two periods, so one merely-late run is not called a failure, floored at the
# old flat window so short-cadence jobs keep healing exactly as before. An
# unknown period falls back to the floor: unschedulable jobs stay covered.
job_stale_after() {
  local period="${1-}" floor="${2:-10800}"
  case "$period" in
    ''|*[!0-9]*) echo "$floor"; return 0 ;;
  esac
  [ "$period" -gt 0 ] || { echo "$floor"; return 0; }
  local w=$((period * 2))
  [ "$w" -lt "$floor" ] && w="$floor"
  echo "$w"
}
