#!/usr/bin/env bash
# Test ci-runner-guard.sh's HEAL_UMBRA_CMD — fully OFFLINE. Fake `systemctl` and
# `sudo` on PATH stand in for the guest. The heal must restart ONLY runner units
# that are not active: restarting the whole "actions.runner.*" glob killed every
# in-flight job on the healthy runners (2026-10-07 09:38).
# Run: bash ops/lib/__tests__/guard-heal.test.sh
set -uo pipefail

SRC="$(cd "$(dirname "$0")" && cd ../.. && pwd)/ci-runner-guard.sh"
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/bin"

# The command exactly as the guard ships it (single-quoted assignment on one line).
CMD=$(sed -n "s/^HEAL_UMBRA_CMD='\(.*\)'\$/\1/p" "$SRC")

# Fake systemctl: list-units prints the scenario; everything else is logged.
cat > "$ROOT/bin/systemctl" <<EOF
#!/bin/bash
if [ "\$1" = list-units ]; then printf '%s\n' "\$FAKE_UNITS"; exit 0; fi
echo "systemctl \$*" >> "$ROOT/calls"
EOF
# Fake sudo: run the rest of the line (it is always systemctl here).
printf '#!/bin/bash\n"$@"\n' > "$ROOT/bin/sudo"
chmod +x "$ROOT/bin/systemctl" "$ROOT/bin/sudo"

_pass=0; _fail=0
check() { # name expected_count pattern
  local n; n=$(grep -c -- "$3" "$ROOT/calls" 2>/dev/null || true); n=${n:-0}
  if [ "$n" = "$2" ]; then _pass=$((_pass+1)); else _fail=$((_fail+1)); echo "FAIL: $1 (expected $2 x '$3', got $n)"; fi
}
run() { : > "$ROOT/calls"; FAKE_UNITS="$1" PATH="$ROOT/bin:$PATH" bash -c "$CMD"; }

[ -n "$CMD" ] || { echo "FAIL: HEAL_UMBRA_CMD not found in $SRC"; exit 1; }

run 'actions.runner.r-a.service loaded active running A
actions.runner.r-b.service loaded failed failed B
actions.runner.r-c.service loaded active running C'
check "dead unit is restarted"                 1 "restart actions.runner.r-b.service"
check "healthy units are NOT restarted"        0 "restart actions.runner.r-a.service"
check "healthy units are NOT restarted (2)"    0 "restart actions.runner.r-c.service"
check "never restarts the whole glob"          0 'restart actions.runner.\*'

run 'actions.runner.r-a.service loaded active running A'
check "all healthy: nothing restarted"         0 "restart"

run 'actions.runner.r-a.service loaded inactive dead A
actions.runner.r-b.service loaded failed failed B'
check "every dead unit restarted"              2 "restart actions.runner"

echo "guard-heal: $_pass passed, $_fail failed"
[ "$_fail" -eq 0 ]
