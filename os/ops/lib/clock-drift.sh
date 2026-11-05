#!/usr/bin/env bash
# Guest clock-drift classification for the CI fleet.
#
# 2026-08-24: fwb-ci6 woke 26 HOURS behind the host after the Mac suspended.
# GitHub refuses any runner operation once the clock is off by more than five
# minutes ("The local machine's clock may be out of sync with the server time"),
# so every runner failed to create a session, crash-looped, and GitHub reaped
# six registrations. The fleet outage looked like a disk problem, then like a
# network problem; it was the clock.
#
# chrony was running the whole time. Its default `makestep 1 3` only steps
# during the first few updates, so after a suspend it slews forever and never
# catches up — a running NTP daemon is NOT evidence of a correct clock.

# clock_drift_level <drift_seconds> [warn] [crit]
#   -> "unknown" | "ok" | "warn" | "crit"
#
# Drift is absolute; a guest ahead of the host is as broken as one behind.
# A non-numeric reading is UNKNOWN, never 0 — an unreachable guest whose clock
# we could not read must not report a perfect clock.
clock_drift_level() {
  local drift="${1-}" warn="${2:-120}" crit="${3:-300}"
  case "$drift" in
    ''|*[!0-9-]*) echo "unknown"; return 0 ;;
  esac
  drift=${drift#-}
  case "$drift" in
    ''|*[!0-9]*) echo "unknown"; return 0 ;;
  esac
  if [ "$drift" -ge "$crit" ]; then echo "crit"
  elif [ "$drift" -ge "$warn" ]; then echo "warn"
  else echo "ok"
  fi
}
