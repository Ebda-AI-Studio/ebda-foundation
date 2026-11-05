# shellcheck shell=bash
# ops/lib/usage-stop.sh - the agent fan-out fanout-stop file written by usage-sentinel.sh (and by Telegram /pause).
#   usage_stop_file     -> path
#   usage_stop_active   -> exit 0 when STOP exists (fan-out must refuse), 1 otherwise
usage_stop_file() { printf '%s' "${USAGE_STATE:-$HOME/.whisky-os-state/usage}/fanout-stop"; }
usage_stop_active() { [ -e "$(usage_stop_file)" ]; }
