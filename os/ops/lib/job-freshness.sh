#!/usr/bin/env bash
# shellcheck shell=bash
# job-freshness.sh — decide, for ONE launchd job, whether it is still running.
#
# WHY THIS IS A LIBRARY AND NOT INLINE IN os-selftest.sh
#
# os-selftest.sh's check_plist_freshness hand-rolled its own cadence parser in
# an inline heredoc: `Weekday` present -> weekly, else -> daily. Meanwhile
# lib/job-cadence.sh already existed, was already installed, was already used by
# heal-watch.sh, and was strictly better — it handles Day/Month, an ARRAY of
# calendar entries, and rejects StartInterval 0/true. Two parsers for one fact
# is how they drift: the inline one called session-mining (Day=1, MONTHLY) a
# DAILY job, so the moment that job writes its first log it would be reported
# stale every single day forever.
#
# The verdict logic lived inside a 100-line shell function that also rendered
# findings, so it could not be called by a test. ops/lib/__tests__/os-selftest.test.sh
# "covered" it by REIMPLEMENTING `window = cadence*2 + 3600` in python and then
# asserting that copy behaved — a test that passes for the wrong reason, green
# no matter what the shipped code does. Extracting the decision makes the real
# code path the thing under test.
#
# THE SHAPES A JOB CAN HAVE, and what each one's evidence actually is:
#
#   SCHEDULED (StartInterval / StartCalendarInterval)
#     Evidence = the mtime of the log it writes, judged against ITS OWN cadence.
#   DAEMON (no schedule at all, KeepAlive / RunAtLoad)
#     Evidence = whether the PROCESS IS ALIVE. A daemon has no cadence, so log
#     mtime is evidence of nothing: a healthy resident process can sit silent
#     for weeks. com.ebda.os.dashboard was handled by being `continue`d out of
#     the loop entirely — checked by nothing at all, which reads as a pass.
#   NEITHER
#     No determinable cadence and no liveness artifact. This must be a FINDING,
#     never a quiet pass — "nothing to check" and "checked, fine" are different
#     answers and only one of them is true.
#
# Verdicts are returned as data (`verdict|age|window|period|logpath`) and the
# caller maps them to severities, so this file has no opinion about findings and
# a test can assert on the verdict rather than on rendered English.

# shellcheck source=./job-cadence.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/job-cadence.sh" 2>/dev/null || true

# _jf_launchctl_state <label> -> running | loaded | absent | unknown
#
# `launchctl print` emits `state = running` plus a `pid = N` line only while the
# process is actually alive; an interval job between runs prints
# `state = not running` and NO pid. "unknown" (launchctl missing, e.g. Linux CI)
# is deliberately NOT "loaded": an absent tool proves nothing, and treating it as
# proof is the fail-open posture this whole file exists to remove.
#
# JF_LAUNCHCTL_OVERRIDE is a TEST SEAM. It is additive only: when unset the real
# launchctl is used, and when launchctl is unavailable the answer is "unknown",
# which every caller below grades as a finding. There is no permissive stub.
_jf_launchctl_state() {
  local label="${1-}"
  if [ -n "${JF_LAUNCHCTL_OVERRIDE-}" ]; then printf '%s\n' "$JF_LAUNCHCTL_OVERRIDE"; return 0; fi
  command -v launchctl >/dev/null 2>&1 || { echo "unknown"; return 0; }
  local out; out="$(launchctl print "gui/$(id -u)/${label}" 2>/dev/null || true)"
  [ -n "$out" ] || { echo "absent"; return 0; }
  if printf '%s' "$out" | grep -qE '^[[:space:]]*state = running$' \
     && printf '%s' "$out" | grep -qE '^[[:space:]]*pid = [0-9]+$'; then
    echo "running"; return 0
  fi
  echo "loaded"
}

# _jf_state_log <label> <state_dir> -> path, or empty
#
# Several jobs write their real audit trail to $STATE/<job>.log and only echo to
# the launchd stream when they have something to alert about. For those the
# plist's StandardOutPath is a 0-byte file frozen at creation, so its mtime is
# evidence of nothing — gate-guard was reported 26 DAYS stale while running every
# single day.
#
# This is an EXPLICIT LIST, not a pattern. The property that makes a state log
# trustworthy is "the job writes to it on EVERY run, including a clean one".
# Guessing $STATE/<name>.log for every job instead swapped one false stale for
# two others (app-error-heal, hung-job-guard), whose state logs are written only
# on findings or not at all. Verify that property before adding a job here.
#
#   gate-guard  — `log "all critical gates active + fresh…"` on every run.
#   heal-watch  — ops/heal-watch.sh ends every pass with an UNCONDITIONAL
#                 `printf '%s [heal-watch] checked %s, %s down\n' >>"$LOG"`,
#                 after the status write and outside every branch. Measured
#                 2026-09-19: 100 of the last 100 lines of ~/.whisky-os-state/heal.log
#                 are run summaries, evenly spaced ~180s, zero non-summary lines.
#                 Its launchd stream log was 35h stale while the job ran fine,
#                 which was the single FAIL in the daily self-test.
_jf_state_log() {
  local label="${1-}" state_dir="${2-}"
  case "$label" in
    com.ebda.os.gate-guard) printf '%s\n' "$state_dir/gate-guard.log" ;;
    com.ebda.os.heal-watch) printf '%s\n' "$state_dir/heal.log" ;;
    *) printf '\n' ;;
  esac
}

# _jf_wake_epoch -> epoch seconds of the host's last wake, or empty if unknown.
#
# WHY: a laptop/desktop that sleeps for a night makes EVERY interval job look
# stale at the next self-test (heal-watch: 180s cadence, 3h window; a >3h sleep
# is a false "stale" -- #197). launchd StartInterval timers do not count sleep
# time, so after waking a job is not due again until up to one period later.
# JF_WAKE_EPOCH_OVERRIDE is a TEST SEAM (additive: unset => real sysctl; no sysctl
# => empty => no tolerance, i.e. the strict verdict stands).
_jf_wake_epoch() {
  if [ -n "${JF_WAKE_EPOCH_OVERRIDE-}" ]; then printf '%s\n' "$JF_WAKE_EPOCH_OVERRIDE"; return 0; fi
  command -v sysctl >/dev/null 2>&1 || return 0
  sysctl -n kern.waketime 2>/dev/null | sed -n 's/.*sec = \([0-9][0-9]*\).*/\1/p'
}

# _jf_window <label> <period> -> seconds
#
# Normally job_stale_after (two periods, floored at 3h). The BACKUP jobs are
# pinned to 36h instead, the same basis as the dump-freshness check further down
# os-selftest.sh: two daily periods is 48h, which would let a missed night pass
# unremarked until the night AFTER — and a backup that did not happen is a DR gap
# on the FIRST night, not the second.
_jf_window() {
  local label="${1-}" period="${2-}"
  case "$label" in
    com.ebda.os.neon-backup|com.ebda.os.ebda-cf-backup) echo $(( 36 * 3600 )); return 0 ;;
  esac
  job_stale_after "$period"
}

# job_freshness_verdict <plist> <now_epoch> [state_dir] [launchagents_dir]
#   -> "verdict|age|window|period|logpath"
#
# verdicts:
#   fresh               log written within the job's own window
#   stale               log older than the window — the job stopped
#   slept               log older than the window, but the host woke < 1 period ago
#                       and the last write predates that wake: not yet due, not dead
#   never-ran           schedule known, declared log absent though a slot passed
#   awaiting-first-run  schedule known, log absent, but the plist is YOUNGER than
#                       one period — the job cannot be late before its first slot
#   not-loaded          no log and launchctl does not know the job
#   daemon-running      no schedule, KeepAlive/RunAtLoad, process alive
#   daemon-stopped      no schedule, KeepAlive/RunAtLoad, process NOT alive
#   daemon-unprovable   daemon shape but launchctl unavailable
#   unprovable          neither a determinable cadence nor a liveness artifact
#   unparseable         the plist does not load
job_freshness_verdict() {
  local plist="${1-}" now="${2:-0}"
  local state_dir="${3:-$HOME/.whisky-os-state}"
  local la_dir="${4:-$HOME/Library/LaunchAgents}"
  [ -f "$plist" ] || { echo "unparseable|0|0||"; return 0; }

  local label job dir
  label="$(basename "$plist" .plist)"
  job="${label#com.ebda.os.}"
  dir="$(dirname "$plist")"

  # One read for the shape facts the cadence library does not expose.
  local facts
  facts="$(python3 - "$plist" <<'PY' 2>/dev/null || true
import plistlib, sys
try:
    d = plistlib.load(open(sys.argv[1], "rb"))
except Exception:
    print("BAD||0"); raise SystemExit(0)
sched = ("StartInterval" in d) or ("StartCalendarInterval" in d)
# KeepAlive may be a bool OR a dict ({'SuccessfulExit': False}); both mean
# "launchd keeps this process resident".
daemonish = bool(d.get("KeepAlive")) or bool(d.get("RunAtLoad"))
print("%s|%s|%d" % ("SCHED" if sched else "NOSCHED",
                    d.get("StandardOutPath", "") or "",
                    1 if daemonish else 0))
PY
)"
  [ -n "$facts" ] || { echo "unparseable|0|0||"; return 0; }
  local shape log_path daemonish
  shape="${facts%%|*}"; facts="${facts#*|}"
  log_path="${facts%|*}"
  daemonish="${facts##*|}"
  [ "$shape" = "BAD" ] && { echo "unparseable|0|0||"; return 0; }

  # ops/launchd/*.plist are TEMPLATES: ops/install.sh substitutes __HOME__ at
  # install time, but this check reads the REPO copy where the token is still
  # literal. Measured 2026-09-19: 40 of 42 jobs carried a log_path that could
  # never exist, so the log branch was skipped for every one of them.
  log_path="${log_path//__HOME__/$HOME}"

  local period; period="$(job_period_seconds "$job" "$dir" 2>/dev/null || echo "")"

  # ── DAEMON: no cadence at all, but launchd keeps it resident ───────────────
  # Judged by PROCESS LIVENESS. Log mtime is meaningless here: a healthy daemon
  # can be silent indefinitely, and a dead one leaves a log that never changes
  # again — the two are indistinguishable by mtime.
  if [ -z "$period" ] && [ "$shape" = "NOSCHED" ] && [ "$daemonish" = "1" ]; then
    case "$(_jf_launchctl_state "$label")" in
      running) echo "daemon-running|0|0||$log_path" ;;
      unknown) echo "daemon-unprovable|0|0||$log_path" ;;
      *)       echo "daemon-stopped|0|0||$log_path" ;;
    esac
    return 0
  fi

  # ── NEITHER a cadence nor a daemon: nothing here can ever fail ─────────────
  # Previously this scored a silent pass (or no counter at all), so a job that
  # will never run again scored exactly what a job that ran an hour ago scored.
  # An unschedulable, unprovable job is a CONFIG defect and is reported as one.
  if [ -z "$period" ]; then
    echo "unprovable|0|0||$log_path"
    return 0
  fi

  local window; window="$(_jf_window "$label" "$period")"

  # Prefer the job's own authoritative state log when it has one.
  local state_log; state_log="$(_jf_state_log "$label" "$state_dir")"
  [ -n "$state_log" ] && [ -s "$state_log" ] && log_path="$state_log"

  # A schedule with nowhere to write cannot be proven fresh by any log. Report
  # it rather than waving it through.
  [ -n "$log_path" ] || { echo "unprovable|0|$window|$period|"; return 0; }

  if [ -f "$log_path" ]; then
    local mtime age
    mtime="$(python3 -c 'import os,sys; print(int(os.path.getmtime(sys.argv[1])))' "$log_path" 2>/dev/null || echo 0)"
    if [ "${mtime:-0}" -gt 0 ]; then
      age=$(( now - mtime ))
      if [ "$age" -le "$window" ]; then
        echo "fresh|$age|$window|$period|$log_path"
      else
        # Stale by the clock -- but was the HOST awake for it? If the last write
        # predates the last wake and the wake was less than one period (+10 min
        # slack) ago, the job has simply not had its first post-wake slot yet.
        # Self-limiting: once a period passes after wake with no write, this
        # stops applying and the job is reported stale as before.
        local wake; wake="$(_jf_wake_epoch)"
        if [ -n "$wake" ] && [ "$mtime" -lt "$wake" ] && [ "$wake" -le "$now" ] \
           && [ $(( now - wake )) -le $(( period + 600 )) ]; then
          echo "slept|$age|$window|$period|$log_path"
        else
          echo "stale|$age|$window|$period|$log_path"
        fi
      fi
      return 0
    fi
  fi

  # No log on disk. launchd CREATES StandardOutPath when it spawns the job, so
  # an absent file means the job has not run since the path was set — EXCEPT
  # that it cannot be late before its first slot has come round. Compare against
  # the INSTALLED plist (what launchd actually loaded), not the repo template
  # whose mtime is only when git last wrote it.
  local ref_plist="$la_dir/$label.plist"
  [ -f "$ref_plist" ] || ref_plist="$plist"
  local pl_mtime pl_age
  pl_mtime="$(python3 -c 'import os,sys; print(int(os.path.getmtime(sys.argv[1])))' "$ref_plist" 2>/dev/null || echo 0)"
  pl_age=$(( now - ${pl_mtime:-0} ))
  if [ "${pl_mtime:-0}" -gt 0 ] && [ "$pl_age" -lt "$period" ]; then
    # Self-limiting: once the plist outlives one period the suppression stops,
    # so a monthly job that genuinely dies is still caught — just not on day one.
    echo "awaiting-first-run|$pl_age|$window|$period|$log_path"
    return 0
  fi

  case "$(_jf_launchctl_state "$label")" in
    absent) echo "not-loaded|0|$window|$period|$log_path" ;;
    *)      echo "never-ran|$pl_age|$window|$period|$log_path" ;;
  esac
}
