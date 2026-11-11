# shellcheck shell=bash
# ops/lib/safe-prune.sh — every AUTOMATIC `umbra prune` goes through safe_umbra_prune.
#
# WHY (2026-10-25 13:24Z). A prune's fstrim froze all guest I/O for ~84 s and timed out two WhatsApp CI tests. The prune
# also wipes /tmp and runs `docker system prune`, none of which belongs under a running job. Policy:
#   host free < SAFE_PRUNE_OVERRIDE_GB (25)  EMERGENCY: full prune now, jobs or not (a full host corrupts the guest)
#   otherwise                                only on an IDLE guest (umbra prune --if-idle: no Runner.Worker, no held
#                                            throttle slot); a busy guest defers to the next run
#   mode routine  (cache cleanup)            --no-fstrim
#   mode reclaim  (host disk is low: the point IS handing space back)   fstrim allowed, but only because idle
#   guest_emergency=1 (guest disk >= crit)   --no-fstrim and NO --if-idle only when the guest disk is nearly full
#                                            (SAFE_PRUNE_GUEST_EMERGENCY_PCT, 97): ENOSPC kills jobs anyway
# safe_umbra_prune <vm> <routine|reclaim> [guest_used_pct]   -> prints the outcome; exit 0 pruned, 3 deferred (busy), 1 failed
# Seams: UMBRA_BIN, SAFE_PRUNE_FREE_GB (host free GB), UMBRA_PRUNE_TIMEOUT.

safe_prune_host_free_gb() {
  if [ -n "${SAFE_PRUNE_FREE_GB:-}" ]; then printf '%s' "$SAFE_PRUNE_FREE_GB"; return; fi
  df -k "$HOME" 2>/dev/null | awk 'NR==2{printf "%d", $4/1048576}'
}

safe_umbra_prune() {
  local vm="$1" mode="${2:-routine}" guest_pct="${3:-0}" free flags out rc ub="${UMBRA_BIN:-umbra}" why
  free="$(safe_prune_host_free_gb)"; case "$free" in ''|*[!0-9]*) free=999 ;; esac
  case "$guest_pct" in ''|*[!0-9]*) guest_pct=0 ;; esac
  if [ "$free" -lt "${SAFE_PRUNE_OVERRIDE_GB:-25}" ]; then
    flags=""; why="override: host free ${free} GB < ${SAFE_PRUNE_OVERRIDE_GB:-25}, pruning even if busy"
  elif [ "$guest_pct" -ge "${SAFE_PRUNE_GUEST_EMERGENCY_PCT:-97}" ]; then
    flags="--no-fstrim"; why="guest disk ${guest_pct}% (nearly full), pruning even if busy, no fstrim"
  elif [ "$mode" = "reclaim" ]; then
    flags="--if-idle"; why="idle guests only (fstrim allowed)"
  else
    flags="--if-idle --no-fstrim"; why="idle guests only, no fstrim"
  fi
  # shellcheck disable=SC2086  # $flags is a deliberate word list
  out="$(_ut "${UMBRA_PRUNE_TIMEOUT:-900}" "$ub" prune "$vm" $flags 2>&1)"; rc=$?
  printf '%s\n' "$out"
  if [ "$rc" -ne 0 ]; then echo "safe-prune: $vm FAILED ($why)"; return 1; fi
  if grep -q "skipped, a CI job is running\|PRUNE_SKIPPED_GUEST_BUSY" <<<"$out"; then echo "safe-prune: $vm deferred, a job is running ($why)"; return 3; fi
  echo "safe-prune: $vm pruned ($why)"; return 0
}
