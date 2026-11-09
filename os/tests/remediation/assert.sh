set -uo pipefail
_PASS=0; _FAIL=0
assert_eq() { # expected actual msg
  if [ "$1" = "$2" ]; then _PASS=$((_PASS+1)); else _FAIL=$((_FAIL+1)); echo "FAIL: $3 — expected [$1] got [$2]"; fi
}
assert_contains() { case "$2" in *"$1"*) _PASS=$((_PASS+1));; *) _FAIL=$((_FAIL+1)); echo "FAIL: $3 — [$2] lacks [$1]";; esac; }
report() { echo "── $_PASS passed, $_FAIL failed ──"; [ "$_FAIL" -eq 0 ]; }
