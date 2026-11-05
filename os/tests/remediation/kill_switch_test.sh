#!/usr/bin/env bash

. "$(dirname "$0")/assert.sh"
export WHISKY_STATE_DIR="$(mktemp -d)"
. "$(dirname "$0")/../../ops/lib/autonomy.sh"
assert_eq "1" "$(autonomy_is_off; echo $?)" "default: autonomy ON (is_off=1)"
autonomy_kill
assert_eq "0" "$(autonomy_is_off; echo $?)" "after kill: autonomy OFF (is_off=0)"
assert_eq "0" "$([ -f "$WHISKY_STATE_DIR/AUTONOMY_OFF" ] && echo 0 || echo 1)" "flag file present"
autonomy_resume
assert_eq "1" "$(autonomy_is_off; echo $?)" "after resume: autonomy ON again"
rm -rf "$WHISKY_STATE_DIR"
report
