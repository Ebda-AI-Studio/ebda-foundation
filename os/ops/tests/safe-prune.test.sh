#!/usr/bin/env bash
# lib/safe-prune.sh: an automatic prune never lands mid-job and never runs fstrim on a busy guest.
set -uo pipefail
cd "$(dirname "$0")/.."; OPS="$(pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1 — got '$2' want '$3'"; fail=$((fail+1)); fi; }
export HOME="$TMP/home"; mkdir -p "$HOME"
. "$OPS/lib/os-state.sh" 2>/dev/null || true
. "$OPS/lib/safe-prune.sh"

cat > "$TMP/umbra" <<EOS
#!/usr/bin/env bash
echo "\$*" > "$TMP/args"
[ -n "\${STUB_OUT:-}" ] && echo "\$STUB_OUT"
exit \${STUB_RC:-0}
EOS
chmod +x "$TMP/umbra"; export UMBRA_BIN="$TMP/umbra"
run() { rm -f "$TMP/args"; safe_umbra_prune "$@" >"$TMP/out" 2>&1; RC=$?; ARGS="$(cat "$TMP/args" 2>/dev/null)"; }

SAFE_PRUNE_FREE_GB=80 run umbra-ci6 routine
ok "routine, host fine: idle-only and no fstrim" "$ARGS" "prune umbra-ci6 --if-idle --no-fstrim"
SAFE_PRUNE_FREE_GB=35 run umbra-ci6 reclaim
ok "reclaim (host disk low): idle-only, fstrim allowed" "$ARGS" "prune umbra-ci6 --if-idle"
SAFE_PRUNE_FREE_GB=20 run umbra-ci6 routine
ok "host free 20 GB < 25: hard override, plain full prune even if busy" "$ARGS" "prune umbra-ci6"
ok "override is stated in the output" "$(grep -c 'override' "$TMP/out")" "1"
SAFE_PRUNE_FREE_GB=80 run umbra-ci6 routine 98
ok "guest disk 98%: no --if-idle but still NO fstrim" "$ARGS" "prune umbra-ci6 --no-fstrim"
SAFE_PRUNE_FREE_GB=80 run umbra-ci6 routine 90
ok "guest disk 90% (crit but not full): still idle-only" "$ARGS" "prune umbra-ci6 --if-idle --no-fstrim"
SAFE_PRUNE_FREE_GB=80 STUB_OUT="umbra-ci6: skipped, a CI job is running (--if-idle)" run umbra-ci6 routine
ok "busy guest: deferred, exit 3 (not a failure)" "$RC" "3"
SAFE_PRUNE_FREE_GB=80 STUB_RC=1 run umbra-ci6 routine
ok "a failing prune is exit 1" "$RC" "1"
SAFE_PRUNE_FREE_GB=80 STUB_OUT="PRUNE_FREED 123" run umbra-ci6 routine
ok "success is exit 0" "$RC" "0"
SAFE_PRUNE_FREE_GB="unreadable" run umbra-ci6 routine
ok "unreadable host free is treated as fine, never as an emergency" "$(echo "$ARGS" | grep -c -- '--if-idle')" "1"

# wiring: no automatic caller may run a bare `umbra prune`
for f in workspace-hygiene.sh ci-runner-guard.sh; do
  ok "$f calls safe_umbra_prune" "$([ "$(grep -c 'safe_umbra_prune' "$OPS/$f")" -ge 1 ] && echo yes || echo no)" "yes"
  ok "$f has no bare umbra prune call" "$(grep -nE '(umbra|"\$ub") prune "' "$OPS/$f" | grep -vc '^[0-9]*:\s*#')" "0"
done
ok "workspace-hygiene refuses to run without the guard lib" "$(grep -c 'lib/safe-prune.sh missing' "$OPS/workspace-hygiene.sh")" "1"

# mutation control: drop --if-idle from the routine branch and the first case must go red
sed 's/flags="--if-idle --no-fstrim"/flags="--no-fstrim"/' "$OPS/lib/safe-prune.sh" > "$TMP/mut.sh"
( . "$TMP/mut.sh"; SAFE_PRUNE_FREE_GB=80 safe_umbra_prune umbra-ci6 routine >/dev/null 2>&1 ); got="$(cat "$TMP/args")"
[ "$got" = "prune umbra-ci6 --if-idle --no-fstrim" ] && { echo "FAIL: MC mutation not caught"; fail=$((fail+1)); } || { echo "PASS: MC without --if-idle the routine case differs (so it is a real test)"; pass=$((pass+1)); }

echo "$pass passed, $fail failed"; [ "$fail" = 0 ]
