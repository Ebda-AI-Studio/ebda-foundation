#!/usr/bin/env bash
# journey-monitor: an all-skip run is WARN (blind), never "all passed"; and the
# env file must reach the journeys (set -a). Fake HOME, fixture journeys, offline.
# (#197: JOURNEY_STORE_STORE_URL unset -> 0 pass / 1 skip was written ok=true.)
set -uo pipefail
cd "$(dirname "$0")/.."; OPS="$(pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
_pass=0; _fail=0
pass() { echo "PASS: $1"; _pass=$((_pass+1)); }
fail() { echo "FAIL: $1"; _fail=$((_fail+1)); }

mkdir -p "$T/j-skip" "$T/j-mixed" "$T/j-env"
cat > "$T/j-skip/needs-env.mjs" <<'MJS'
if (!process.env.JOURNEY_TEST_URL) { console.log(JSON.stringify({journey:"needs-env",ok:true,skipped:true,detail:"JOURNEY_TEST_URL not set - skipping"})); process.exit(0); }
console.log(JSON.stringify({journey:"needs-env",ok:true,detail:"saw " + process.env.JOURNEY_TEST_URL}));
MJS
cp "$T/j-skip/needs-env.mjs" "$T/j-mixed/needs-env.mjs"; cp "$T/j-skip/needs-env.mjs" "$T/j-env/needs-env.mjs"
echo 'console.log(JSON.stringify({journey:"always-pass",ok:true,detail:"fine"}));' > "$T/j-mixed/always-pass.mjs"

run() {   # <journey dir> <env file> -> OUT, STATUS (status json text)
  local h="$T/home-$RANDOM"; mkdir -p "$h"
  OUT="$(HOME="$h" WHISKY_SERVICES_ENV="$2" JOURNEY_DIR="$1" DRY_RUN=0 bash "$OPS/journey-monitor.sh" 2>&1)"; RC=$?
  STATUS="$(cat "$h/.whisky-os-state/journey-monitor-status.json" 2>/dev/null)"
}
st_ok() { printf '%s' "$STATUS" | python3 -c "import sys,json;print(json.load(sys.stdin).get('ok'))" 2>/dev/null; }

run "$T/j-skip" /dev/null
[ "$(st_ok)" = "warn" ] && pass "all-skip -> status ok='warn' (not true)" || fail "all-skip status ok=$(st_ok): $STATUS"
echo "$OUT" | grep -q "WARN — all 1 journey(s) SKIPPED" && pass "all-skip prints a WARN naming the var to set" || fail "no WARN line: $OUT"
echo "$OUT" | grep -q "JOURNEY_STORE_STORE_URL" && pass "WARN names JOURNEY_STORE_STORE_URL" || fail "var not named"
[ "$RC" -eq 0 ] && pass "all-skip stays fail-open (exit 0)" || fail "rc=$RC"

run "$T/j-mixed" /dev/null
[ "$(st_ok)" = "true" ] && pass "1 pass + 1 skip is still healthy (ok=true)" || fail "mixed status ok=$(st_ok): $STATUS"

# plain KEY=value (no export) must reach the node journey
echo 'JOURNEY_TEST_URL=https://shop.example.com' > "$T/svc.env"
run "$T/j-env" "$T/svc.env"
echo "$OUT" | grep -q "PASS  needs-env — saw https://shop.example.com" && [ "$(st_ok)" = "true" ] \
  && pass "env file value reaches the journey (set -a): real run, not skip" || fail "env not exported: $OUT"

echo "== MUTATION CHECKS =="
M1="$T/m1"; mkdir -p "$M1"; cp -R "$OPS/lib" "$M1/lib"; cp "$OPS/journey-monitor.sh" "$M1/"
python3 - "$M1/journey-monitor.sh" <<'PY' || fail "mutation 1 setup"
import sys; p=sys.argv[1]; t=open(p).read()
old='elif [ "$PASS_COUNT" -eq 0 ] && [ "$SKIP_COUNT" -gt 0 ]; then'
assert old in t
open(p,'w').write(t.replace(old,'elif false; then',1))
PY
h="$T/hm1"; mkdir -p "$h"; HOME="$h" WHISKY_SERVICES_ENV=/dev/null JOURNEY_DIR="$T/j-skip" DRY_RUN=0 bash "$M1/journey-monitor.sh" >/dev/null 2>&1
[ "$(python3 -c "import json;print(json.load(open('$h/.whisky-os-state/journey-monitor-status.json'))['ok'])")" = "true" ] \
  && pass "mutation 1 (all-skip branch removed) is caught: reverts to ok=true" || fail "MUTATION 1 survived"
M2="$T/m2"; mkdir -p "$M2"; cp -R "$OPS/lib" "$M2/lib"; cp "$OPS/journey-monitor.sh" "$M2/"
python3 - "$M2/journey-monitor.sh" <<'PY' || fail "mutation 2 setup"
import sys; p=sys.argv[1]; t=open(p).read()
old='{ set -a; . "$SVC_ENV"; set +a; }'
assert old in t
open(p,'w').write(t.replace(old,'. "$SVC_ENV"',1))
PY
h="$T/hm2"; mkdir -p "$h"; o="$(HOME="$h" WHISKY_SERVICES_ENV="$T/svc.env" JOURNEY_DIR="$T/j-env" DRY_RUN=0 bash "$M2/journey-monitor.sh" 2>&1)"
echo "$o" | grep -q "SKIP  needs-env" && pass "mutation 2 (drop set -a) is caught: journey skips" || fail "MUTATION 2 survived"
echo; echo "journey-allskip.test: $_pass passed, $_fail failed"; [ "$_fail" -eq 0 ]
