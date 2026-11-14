#!/usr/bin/env bash
# Ebda AI OS — runner-restore.sh
#
# Target of the `runner-offline` remediation route (ops/dispatch-route.sh).
# Delegates to ci-runner-guard.sh, which judges the native Mac runner fleet from the
# GitHub API (`gh api orgs/<org>/actions/runners`) and reports/pages when a whole org
# or label pool is offline. The runners are launchd services on this Mac
# (actions.runner.<org>.<name>); the guard never starts or rebuilds a machine, so a
# human restarts a dead one with `launchctl kickstart -k gui/$(id -u)/actions.runner.<org>.<name>`.
# The guard is idempotent, so calling it from the event route is safe at any cadence.
#
# HISTORY: this used to boot and heal the Umbra Linux CI VM. Umbra was retired
# 2026-11-14 (Ruling UMBRA-RETIRE-1), so there is nothing to boot any more.
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
