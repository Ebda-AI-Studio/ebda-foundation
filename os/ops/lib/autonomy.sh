# shellcheck shell=bash
# autonomy.sh — the global kill switch shared by the dispatcher + telegram daemon.
_AUT_FLAG() { echo "${WHISKY_STATE_DIR:-$HOME/.whisky-os-state}/AUTONOMY_OFF"; }
autonomy_kill()   { mkdir -p "$(dirname "$(_AUT_FLAG)")"; : > "$(_AUT_FLAG)"; }
autonomy_resume() { rm -f "$(_AUT_FLAG)"; }
autonomy_is_off() { [ -f "$(_AUT_FLAG)" ]; }