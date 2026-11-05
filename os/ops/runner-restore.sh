#!/usr/bin/env bash
# Whisky AI OS — runner-restore.sh
#
# Target of the `runner-offline` remediation route (ops/dispatch-route.sh).
# Delegates to ci-runner-guard.sh, which owns runner healing: it boots a stopped
# guest, reboots a hung one (VM running + SSH dead), restarts dead runner
# services, and alerts. The guard is idempotent and self-coordinating (wr_claim),
# so calling it from the event route is safe at any cadence.
#
# HISTORY — why this is now a delegator. It used to be a one-shot restorer for
# the 2026-07-13 outage: wait for host memory, boot `umbra-ci5`, then REGISTER two
# repo-scoped runners named after the guest and flip repos back to self-hosted.
# By 2026-08-03 that was both dead and dangerous:
#
#   * umbra-ci5 was DELETED 2026-07-30, so `umbra list | grep "^umbra-ci5 "` matched
#     nothing and the script early-exited on every tick — inert for weeks while
#     still showing up in `launchctl list` as a working safety net.
#   * The one guest that exists, $OS_VM, already runs NINE correctly-named
#     runner services as systemd units. Renaming umbra-ci5 -> $OS_VM would have
#     re-armed the registration path and stacked duplicate, wrongly-named runners
#     on top of them. The rename was the destructive option, not the fix.
#
# Booting the guest restarts its runner services by itself, so no registration is
# needed or wanted here. Registration stays a deliberate manual act
# (`umbra runner add`) — see feedback-umbra-ci-runner-recovery-and-gotchas.
#
# The ${OS_LAUNCHD_PREFIX}.runner-restore LaunchAgent (every 15 min) was removed
# 2026-08-03; it only duplicated ci-runner-guard's own 30-min timer. This script
# is event-driven now.
# shellcheck source=lib/os-config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/os-config.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-config.sh" 2>/dev/null || true
command -v os_config_load >/dev/null 2>&1 && os_config_load
set -uo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"

GUARD="${RUNNER_GUARD:-$HOME/.claude/scripts/ci-runner-guard.sh}"

if [ ! -f "$GUARD" ]; then
  echo "runner-restore: guard not found at $GUARD — cannot heal" >&2
  exit 1
fi

exec bash "$GUARD" "$@"
