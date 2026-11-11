#!/usr/bin/env bash
# isp-188-watch.sh - hourly: every merchant-facing host must resolve outside 188.114.96.0/23 (blocked by the Egyptian ISP).
# Runs isp-188-watch.mjs (DoH resolution, skip-if-unchanged) and hands any findings to the brain via lib/brain-post.sh (kind
# isp-block-range is an ALERT kind there: one P1 message, no hands job). DRY_RUN=1 posts nothing.
# shellcheck source=lib/os-config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/os-config.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-config.sh" 2>/dev/null || true
command -v os_config_load >/dev/null 2>&1 && os_config_load
set -uo pipefail
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$D/lib/brain-post.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/brain-post.sh" || exit 2
STATE="${OS_STATE_DIR:-$HOME/.whisky-os-state}/isp-188-state.json"
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
CONF="$D/lib/isp-188-hosts.json"
node "$D/isp-188-watch.mjs" --config "$CONF" --state "$STATE" --out "$tmp" "$@" || { echo "isp-188-watch: check failed to run" >&2; exit 1; }
brain_post_findings "$tmp"; rc=$?
[ "$rc" = 10 ] && rc=0 # spooled for the brain is delivered enough
exit "$rc"
