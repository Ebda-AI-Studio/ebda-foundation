# shellcheck shell=bash
# ops/lib/runner-fleet.sh — is the self-hosted runner fleet intentionally PARKED?
#
# WHY THIS EXISTS (2026-08-09). All three CI repos were routed to cloud
# (USE_SELF_HOSTED=false) on 2026-08-08 05:17, but nothing told the fleet's
# WATCHERS or its HEALER. So a runner that no CI depended on kept paging:
# ci-runner-guard hard-rebooted a dead guest every ~32.7 min for three days, and
# the runner-health-check crons on CRM + WBS fired every 15 min. ~30 Telegram
# messages + as many red "Run failed" GitHub notifications overnight, all about
# infrastructure that was deliberately out of service.
#
# That is the [service-pause] rule: parking a service means sweeping every
# WAKER, WATCHER and the HEALER.
#
# This is a THIN WRAPPER over `service_paused` in lib/os-state.sh — deliberately.
# That same rule says a watcher which grows its own private check is how the
# noise comes back, so the marker lives where every other paused service's does:
#   ~/.whisky-os-state/runner-fleet-paused
# Park = create it, un-park = delete it. Its CONTENTS are documentation (first
# non-comment line is used as the human reason); only its EXISTENCE is the signal.
#
# Runtime state, not deployed config: a marker under ~/.whisky-os-state survives
# the script sync that silently re-armed the WBS healer mid-pause on 2026-08-06.
#
# PARKED MUST NOT MEAN BLIND. Callers that stand down on `fleet_parked` are
# still required to assert the safety invariant — every CI repo must be on
# cloud. Parked fleet + USE_SELF_HOSTED=true is the genuinely dangerous state:
# CI queues forever against a runner that will never arrive, and the watcher
# that would have said so is the one standing down. Alert LOUDLY on that.
#
# Usage (source lib/os-state.sh FIRST — this needs service_paused):
#   . "$HOME/.claude/scripts/lib/os-state.sh"
#   . "$HOME/.claude/scripts/lib/runner-fleet.sh"
#   if fleet_parked; then ... fi
#   fleet_park_reason   # one-line human reason, for the alert/status text

FLEET_PARK_FILE="${FLEET_PARK_FILE:-$HOME/.whisky-os-state/runner-fleet-paused}"

# 0 = parked (out of service on purpose), 1 = in service.
#
# FAIL CLOSED on a missing os-state.sh: no service_paused means we cannot prove a
# park, and "unknown" must never read as "parked" — that would silence a real
# outage. Fall back to the marker check directly so ordering mistakes degrade to
# correct behaviour rather than to silence.
fleet_parked() {
  if command -v service_paused >/dev/null 2>&1; then
    service_paused runner-fleet
  else
    [ -f "$FLEET_PARK_FILE" ]
  fi
}

# First non-comment, non-blank line of the marker, or a generic fallback.
fleet_park_reason() {
  [ -f "$FLEET_PARK_FILE" ] || { printf 'not parked'; return; }
  local line
  line=$(grep -m1 -vE '^[[:space:]]*(#|$)' "$FLEET_PARK_FILE" 2>/dev/null)
  printf '%s' "${line:-parked (no reason recorded in $FLEET_PARK_FILE)}"
}