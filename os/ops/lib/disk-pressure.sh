#!/usr/bin/env bash
# Disk-pressure classification (host disk of the Mac that runs the CI runners).
#
# Extracted so the rule below is testable. A full CI disk takes every runner
# down and runs sit queued forever, so the level is computed once, here.

# disk_pressure_level <used_pct> [warn_pct] [crit_pct]
#   -> "unknown" | "ok" | "warn" | "crit"
#
# An unreadable or non-numeric reading is UNKNOWN, never "ok" and never 0%.
# Treating a guest we could not reach as 0% used is precisely how a dead host
# reports healthy — the failure mode this guard exists to catch.
# shellcheck source=os-config.sh
command -v os_config_load >/dev/null 2>&1 || . "$(dirname "${BASH_SOURCE[0]}")/os-config.sh" 2>/dev/null || true
[ -n "${OS_ORG:-}" ] || ! command -v os_config_load >/dev/null 2>&1 || os_config_load
disk_pressure_level() {
  local used="${1-}" warn="${2:-80}" crit="${3:-90}"
  case "$used" in
    ''|*[!0-9]*) echo "unknown"; return 0 ;;
  esac
  if [ "$used" -ge "$crit" ]; then echo "crit"
  elif [ "$used" -ge "$warn" ]; then echo "warn"
  else echo "ok"
  fi
}

# host_disk_used_pct <mount-path>
#   -> integer used-percent, or '' when unreadable (which disk_pressure_level
#      then classifies as "unknown", never "ok").
#
# APFS: `df /` reports the sealed system volume, whose used% is meaningless —
# 12 GB of 460 GB while the Data volume beside it is at 98%. Container FREE space
# is shared so the available figure agrees, but used% does not. Callers pass
# /System/Volumes/Data on macOS. Added 2026-09-04 after a 98%-full host
# wedged the CI fleet.
host_disk_used_pct() {
  local vol="${1:-/}"
  [ -d "$vol" ] || return 0            # no path -> empty -> unknown
  df -P "$vol" 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5); print $5}' | tr -dc '0-9'
}

# host_disk_free_gb <mount-path> -> integer GB free, or '' when unreadable.
host_disk_free_gb() {
  local vol="${1:-/}"
  [ -d "$vol" ] || return 0
  # `-P -k` is POSIX: 1024-byte blocks on BOTH BSD/macOS and GNU coreutils.
  # `df -g` is a BSD extension that GNU df rejects outright, so on Linux this
  # returned EMPTY and the host read as "unknown" free space. That is not a
  # cosmetic portability nit: the CI guest this guard protects IS Linux, so the
  # free-space half of the watchdog would have been blind exactly where the
  # 98%-full wedge happened. Caught by this suite failing on a cloud runner.
  df -Pk "$vol" 2>/dev/null | awk 'NR==2{printf "%d", $4/1048576}' | tr -dc '0-9'
}

