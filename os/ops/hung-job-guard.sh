#!/usr/bin/env bash
# Whisky AI OS — hung-job guard.
#
# WHY THIS EXISTS (2026-08-03). Two scheduled jobs were found wedged mid-run:
#   • ci-runner-guard — 3 processes stuck 4h07m on one `umbra shell` (umbra's
#     own ssh, no ConnectTimeout, stale cached port).
#   • gate-guard      — a single run started 24 DAYS earlier and never returned.
#
# launchd will not start a new run while one is in flight, so in both cases the
# job silently stopped doing its job: no log, no alert, and `launchctl` still
# reporting it "running". os-selftest could only see it indirectly, as a stale
# log. A monitor that hangs does not fail — it goes QUIET, and quiet reads
# exactly like healthy.
#
# The per-script fix is a wall clock on every network call. That is correct and
# was applied to ci-runner-guard, but 16 scheduled scripts make ~60 unbounded
# `gh`/`curl`/`ssh` calls between them, and any future script re-opens the hole
# the moment someone forgets. This guard is the BACKSTOP: it does not care WHY
# a job is stuck, only that it has outlived any plausible run. One mechanism,
# every job, including ones not yet written.
#
# Deliberately makes NO network calls and shells out only to launchctl/ps/kill,
# so it cannot become an instance of the very class it polices
# (see: a monitor must not ride what it monitors).
#
#   hung-job-guard.sh            kill anything over its ceiling
#   HUNG_GUARD_DRY=1 …           report only, kill nothing
# shellcheck source=lib/os-config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/os-config.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-config.sh" 2>/dev/null || true
command -v os_config_load >/dev/null 2>&1 && os_config_load
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/os-state.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-state.sh" 2>/dev/null || true
NOTIFY="$HERE/notify.sh"
DRY="${HUNG_GUARD_DRY:-0}"
SELF_LABEL="${OS_LAUNCHD_PREFIX}.hung-job-guard"

# Ceiling = SLACK × StartInterval, never below FLOOR. A job that legitimately
# runs longer than twice its own interval is already overlapping itself, which
# is its own bug.
SLACK="${HUNG_GUARD_SLACK:-2}"
FLOOR="${HUNG_GUARD_FLOOR:-1800}"          # 30 min
NO_INTERVAL_CEILING="${HUNG_GUARD_DEFAULT:-10800}"   # 3h for calendar-scheduled jobs

killed=(); checked=0

# ps etime -> seconds. Formats: SS, MM:SS, HH:MM:SS, D-HH:MM:SS.
etime_secs() {
  local e="$1"
  local d=0
  local rest="$e"
  case "$e" in *-*) d="${e%%-*}"; rest="${e#*-}";; esac
  local IFS=:; set -- $rest
  # 10# forces base 10. ps pads fields with a leading zero ("00:09"), and bash
  # reads a 0-prefixed literal as OCTAL — "09" is not a valid octal digit, so
  # the arithmetic ABORTS, $secs comes out empty, and the `-le` test below
  # errors out. That failure is not inert: a failed test falls through to the
  # kill path, so the guard would have killed HEALTHY jobs regardless of their
  # ceiling. Caught only because the end-to-end test printed the arithmetic
  # error next to a "success".
  case $# in
    3) echo $(( d*86400 + 10#$1*3600 + 10#$2*60 + 10#$3 )) ;;
    2) echo $(( d*86400 + 10#$1*60 + 10#$2 )) ;;
    1) echo $(( d*86400 + 10#$1 )) ;;
    *) echo 0 ;;
  esac
}

plist_val() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null | tr -d '\n '; }

for p in "$HOME"/Library/LaunchAgents/${OS_LAUNCHD_PREFIX}.*.plist; do
  [ -f "$p" ] || continue
  lbl="$(basename "$p" .plist)"
  [ "$lbl" = "$SELF_LABEL" ] && continue

  # ── The safety rule, learned the hard way ──────────────────────────────
  # ONLY police jobs with an explicit cadence. If a plist declares no
  # StartInterval and no StartCalendarInterval, it is a DAEMON and running
  # forever is its correct behaviour — there is no "too long" to compare
  # against, so this guard has no business forming an opinion.
  #
  # The first dry run proposed killing ${OS_LAUNCHD_PREFIX}.umbrad (up 15h) because
  # KeepAlive can be a DICT (`{ SuccessfulExit = false; }`), which does not
  # equal the string "true" — the daemon test silently failed open and the
  # fallback 3h ceiling applied. That would have killed the Umbra daemon that
  # owns the CI guest. Any KeepAlive at all now means daemon, and the cadence
  # requirement below is the real backstop.
  case "$(plist_val "$p" KeepAlive)" in "") : ;; *) continue ;; esac
  iv="$(plist_val "$p" StartInterval)"
  cal="$(/usr/libexec/PlistBuddy -c "Print :StartCalendarInterval" "$p" 2>/dev/null | head -1)"
  if [ -z "$iv" ] && [ -z "$cal" ]; then continue; fi

  info="$(launchctl print "gui/$(id -u)/$lbl" 2>/dev/null)" || continue
  printf '%s' "$info" | grep -q "state = running" || continue
  pid="$(printf '%s' "$info" | grep -oE 'pid = [0-9]+' | head -1 | grep -oE '[0-9]+')"
  [ -n "${pid:-}" ] || continue
  et="$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ')"
  [ -n "$et" ] || continue
  secs="$(etime_secs "$et")"
  checked=$((checked+1))

  if [ -n "$iv" ] && [ "$iv" -gt 0 ] 2>/dev/null; then
    ceiling=$(( iv * SLACK ))
    [ "$ceiling" -lt "$FLOOR" ] && ceiling="$FLOOR"
  else
    ceiling="$NO_INTERVAL_CEILING"
  fi

  # Fail SAFE: an elapsed time we cannot parse is not evidence of a hang.
  case "$secs" in ''|*[!0-9]*) continue ;; esac
  [ "$secs" -le "$ceiling" ] && continue

  if [ "$DRY" = "1" ]; then
    killed+=("$lbl (pid $pid, ${et} > ceiling ${ceiling}s) — DRY RUN, not killed")
    continue
  fi

  # TERM the whole process group first: these jobs fork children (ssh, gh,
  # curl) and killing only the parent orphans the child that is actually
  # blocked, which is what leaves the schedule wedged.
  pkill -TERM -P "$pid" 2>/dev/null
  kill -TERM "$pid" 2>/dev/null
  sleep 3
  if kill -0 "$pid" 2>/dev/null; then
    pkill -KILL -P "$pid" 2>/dev/null
    kill -KILL "$pid" 2>/dev/null
  fi
  killed+=("$lbl — was stuck ${et} (ceiling ${ceiling}s); killed so the schedule can resume")
done

if [ ${#killed[@]} -gt 0 ]; then
  msg="⏱️ Hung-job guard: ${#killed[@]} stuck job(s) of $checked checked"
  for k in ${killed[@]+"${killed[@]}"}; do msg="$msg
  • $k"; done
  echo "$msg"
  [ "$DRY" = "1" ] || { [ -x "$NOTIFY" ] && printf '%s' "$msg" | "$NOTIFY" "Hung job" >/dev/null 2>&1 || true; }
  command -v write_status >/dev/null 2>&1 && \
    write_status "hung-job-guard" "false" "${#killed[@]} stuck job(s) killed" '{}' 2>/dev/null || true
else
  echo "hung-job-guard: $checked running job(s) checked, none over ceiling"
  command -v write_status >/dev/null 2>&1 && \
    write_status "hung-job-guard" "true" "$checked job(s) checked, none stuck" '{}' 2>/dev/null || true
fi
