# shellcheck shell=bash
# ops/lib/umbra-provisioning.sh — is `umbra rebuild` provisioning a machine?
#
# WHY THIS EXISTS (2026-10-16). At 02:53 ci-runner-guard rebooted a brand-new
# $OS_VM in the middle of `umbra rebuild` ("SSH dead + no runner → reboot").
# From outside, a guest being provisioned looks exactly like a hung one: ssh
# drops across the HWE-kernel restart and no runner exists yet. The guard had to
# be unloaded by hand for the window (Ruling R-2026-10-16-1).
#
# umbra rebuild (umbra cmd/umbra/provisioning.go) now writes
#   ${UMBRA_ROOT:-~/.umbra}/provisioning/<machine>
# with key=value lines; only `expires=<unix epoch>` is load-bearing here
# (phase= is shown to humans). It is rewritten at the start of every rebuild
# step with a 60-min expiry, removed on success, and KEPT on failure (a human is
# finishing the guest by hand). That key=value format is the contract.
#
# THE TTL IS THE POINT. A killed rebuild can never remove its marker, so the
# signal is the expiry, never the file's existence — a dead rebuild disables
# the guard for at most one step's TTL. An expiry more than
# UMBRA_PROVISIONING_MAX_S (4h) ahead is refused as bogus.
#
# HOST SLEEP. umbra re-stamps expires= every 30s from the wall clock while a
# step runs, but a guard launched the moment the Mac wakes can read a stamp from
# before the sleep. So an EXPIRED marker still counts while its pid= is a live
# process whose command matches UMBRA_PROVISIONING_PROC_RE (pid reuse by some
# other program does not count), for at most UMBRA_PROVISIONING_MAX_S past the
# expiry. A dead pid keeps the pure TTL semantics.
#
# FAIL OPEN. Anything unreadable or malformed means "not provisioning", i.e. the
# guard's normal behaviour. A broken marker must never silence the guard.
#
# Usage:
#   if reason="$(umbra_provisioning $OS_VM)"; then … stand down …; fi
#   umbra_provisioning <machine> [now-epoch]   # now is injectable for tests

# shellcheck source=os-config.sh
command -v os_config_load >/dev/null 2>&1 || . "$(dirname "${BASH_SOURCE[0]}")/os-config.sh" 2>/dev/null || true
[ -n "${OS_ORG:-}" ] || ! command -v os_config_load >/dev/null 2>&1 || os_config_load
UMBRA_PROVISIONING_MAX_S="${UMBRA_PROVISIONING_MAX_S:-14400}"
# Command-name match for the rebuild process recorded in pid= (see below).
UMBRA_PROVISIONING_PROC_RE="${UMBRA_PROVISIONING_PROC_RE:-umbra}"

# 0 + a one-line reason on stdout when <machine> is being provisioned; 1 otherwise.
umbra_provisioning() {
  local m="${1:-}" now="${2:-}" f exp phase
  case "$m" in ''|*/*|.*) return 1 ;; esac
  [ -n "$now" ] || now="$(date +%s)"
  f="${UMBRA_ROOT:-$HOME/.umbra}/provisioning/$m"
  [ -f "$f" ] || return 1
  exp="$(sed -n 's/^expires=//p' "$f" 2>/dev/null | head -n1)"
  case "$exp" in ''|*[!0-9]*) return 1 ;; esac
  phase="$(sed -n 's/^phase=//p' "$f" 2>/dev/null | head -n1)"
  if [ "$exp" -le "$now" ]; then
    local pid comm
    pid="$(sed -n 's/^pid=//p' "$f" 2>/dev/null | head -n1)"
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    [ $((now - exp)) -le "$UMBRA_PROVISIONING_MAX_S" ] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    comm="$(ps -o comm= -p "$pid" 2>/dev/null)"
    printf '%s' "$comm" | grep -Eq "$UMBRA_PROVISIONING_PROC_RE" || return 1
    printf 'umbra rebuild in progress (phase %s; marker expired but rebuild pid %s is still running — host sleep)\n' \
      "${phase:-unknown}" "$pid"
    return 0
  fi
  [ $((exp - now)) -le "$UMBRA_PROVISIONING_MAX_S" ] || return 1
  printf 'umbra rebuild in progress (phase %s, guard resumes in %s min)\n' \
    "${phase:-unknown}" $(( (exp - now + 59) / 60 ))
}
