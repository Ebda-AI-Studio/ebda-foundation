#!/usr/bin/env bash
# Test journey-monitor.sh — OFFLINE (no network, no real prod URLs).
# Covers: pass journey, fail journey, crash-resilience, missing-node handling.
# Run: bash ops/lib/__tests__/journey-monitor.test.sh
set -euo pipefail

RUNNER="$(cd "$(dirname "$0")/../.." && pwd)/journey-monitor.sh"
FIXTURES="$(mktemp -d)"
trap 'rm -rf "$FIXTURES"' EXIT

_pass=0; _fail=0

assert() {
  local label="$1" cond="$2"
  if eval "$cond"; then
    echo "PASS: $label"; _pass=$((_pass + 1))
  else
    echo "FAIL: $label"; _fail=$((_fail + 1))
  fi
}

# ---- build fixture journeys (pure node, no network) ----

# Journey that always passes (exit 0, ok:true)
cat > "$FIXTURES/always-pass.mjs" <<'MJS'
#!/usr/bin/env node
// Fixture: always passes — no network, no deps
console.log(JSON.stringify({journey:"always-pass",ok:true,detail:"fixture always ok"}));
process.exit(0);
MJS

# Journey that always fails (exit 1, ok:false)
cat > "$FIXTURES/always-fail.mjs" <<'MJS'
#!/usr/bin/env node
// Fixture: always fails — simulates a broken outcome assertion
console.log(JSON.stringify({journey:"always-fail",ok:false,detail:"fixture: expected marker not found in response body"}));
process.exit(1);
MJS

# Journey that requires env and skips when unset
cat > "$FIXTURES/needs-env.mjs" <<'MJS'
#!/usr/bin/env node
if (!process.env.JOURNEY_FAKE_URL) {
  console.log(JSON.stringify({journey:"needs-env",ok:true,skipped:true,detail:"JOURNEY_FAKE_URL not set — skipping"}));
  process.exit(0);
}
console.log(JSON.stringify({journey:"needs-env",ok:true,detail:"env was set"}));
process.exit(0);
MJS

# Journey that crashes (simulates syntax error / uncaught throw)
cat > "$FIXTURES/crashes.mjs" <<'MJS'
#!/usr/bin/env node
// Simulate uncaught error — outputs nothing useful, exits non-zero
throw new Error("fixture crash: simulated unhandled error");
MJS

chmod +x "$FIXTURES/always-pass.mjs" "$FIXTURES/always-fail.mjs" "$FIXTURES/needs-env.mjs" "$FIXTURES/crashes.mjs"

# ---- helper: run the monitor with the fixture dir ----
run_monitor() {
  JOURNEY_DIR="$FIXTURES" DRY_RUN=0 bash "$RUNNER" 2>/dev/null || true
}

run_monitor_dry() {
  JOURNEY_DIR="$FIXTURES" DRY_RUN=1 bash "$RUNNER" 2>/dev/null || true
}

# ---- test 1: runner exits 0 even with a failing journey (fail-open) ----
EXIT_CODE=0
JOURNEY_DIR="$FIXTURES" DRY_RUN=0 bash "$RUNNER" >/dev/null 2>&1 || EXIT_CODE=$?
assert "runner exits 0 despite a failing journey (fail-open)" "[ '$EXIT_CODE' -eq 0 ]"

# ---- test 2: a failing journey produces a journey-fail finding ----
STATE_DIR="$HOME/.whisky-os-state"
FINDINGS="$STATE_DIR/journey-findings.json"
run_monitor >/dev/null

assert "journey-findings.json written when journey fails" "[ -f '$FINDINGS' ]"

if [ -f "$FINDINGS" ]; then
  assert "journey-fail finding has class=journey-fail" "python3 -c \"
import json
d=json.load(open('$FINDINGS'))
assert any(f['class']=='journey-fail' for f in d.get('findings',[])), 'no journey-fail finding'
\" 2>/dev/null"

  assert "journey-fail finding references always-fail journey" "python3 -c \"
import json
d=json.load(open('$FINDINGS'))
fails=[f for f in d.get('findings',[]) if f['class']=='journey-fail']
assert any('always-fail' in f.get('title','') for f in fails), 'always-fail not in findings: %s' % fails
\" 2>/dev/null"

  assert "journey-fail severity is high" "python3 -c \"
import json
d=json.load(open('$FINDINGS'))
fails=[f for f in d.get('findings',[]) if f['class']=='journey-fail']
assert all(f.get('severity')=='high' for f in fails), 'not high severity: %s' % fails
\" 2>/dev/null"

  assert "passing journey does NOT appear as journey-fail" "python3 -c \"
import json
d=json.load(open('$FINDINGS'))
fails=[f for f in d.get('findings',[]) if f['class']=='journey-fail']
assert not any('always-pass' in str(f) for f in fails), 'always-pass wrongly appears as fail'
\" 2>/dev/null"
fi

# ---- test 3: DRY_RUN=1 lists journeys and exits 0 without writing state ----
rm -f "$FINDINGS"
OUT_DRY=$(JOURNEY_DIR="$FIXTURES" DRY_RUN=1 bash "$RUNNER" 2>/dev/null || true)
assert "DRY_RUN lists journey files" "printf '%s' '$OUT_DRY' | grep -q 'DRY_RUN'"
assert "DRY_RUN does not run journeys or write findings" "[ ! -f '$FINDINGS' ]"

# ---- test 4: skip journey when env unset (no penalty) ----
# Run with only needs-env.mjs (override JOURNEY_DIR to a tmp single-file dir)
SINGLE="$(mktemp -d)"; trap 'rm -rf "$SINGLE"' EXIT
cp "$FIXTURES/needs-env.mjs" "$SINGLE/"
run_single() { JOURNEY_DIR="$SINGLE" DRY_RUN=0 bash "$RUNNER" 2>/dev/null || true; }
EXIT_SKIP=0
JOURNEY_DIR="$SINGLE" DRY_RUN=0 bash "$RUNNER" >/dev/null 2>&1 || EXIT_SKIP=$?
assert "journey with unset env skips cleanly (exit 0)" "[ '$EXIT_SKIP' -eq 0 ]"

# ---- test 5: no journeys dir → runner exits 0 (fail-open) ----
EMPTY="$(mktemp -d)"
EXIT_EMPTY=0
JOURNEY_DIR="$EMPTY" DRY_RUN=0 bash "$RUNNER" >/dev/null 2>&1 || EXIT_EMPTY=$?
rm -rf "$EMPTY"
assert "empty journeys dir exits 0 (fail-open)" "[ '$EXIT_EMPTY' -eq 0 ]"

# ---- test 6: crashed journey does NOT kill the runner ----
CRASH_ONLY="$(mktemp -d)"; trap 'rm -rf "$CRASH_ONLY"' EXIT
cp "$FIXTURES/crashes.mjs" "$CRASH_ONLY/"
EXIT_CRASH=0
JOURNEY_DIR="$CRASH_ONLY" DRY_RUN=0 bash "$RUNNER" >/dev/null 2>&1 || EXIT_CRASH=$?
assert "crashed journey does not kill runner (exit 0)" "[ '$EXIT_CRASH' -eq 0 ]"

# ---- test 7: missing-node handling ----
# Create a PATH-visible directory that has everything EXCEPT node, so python3/bash
# still work but `command -v node` returns empty → tests the no-node branch.
NONODE_DIR="$(mktemp -d)"; trap 'rm -rf "$NONODE_DIR"' EXIT
# Symlink all needed tools except node into the fake PATH dir
for tool in python3 bash uuidgen; do
  _bin="$(command -v "$tool" 2>/dev/null || true)"
  [ -n "$_bin" ] && ln -s "$_bin" "$NONODE_DIR/$tool" 2>/dev/null || true
done
EXIT_NONODE=0
PATH="$NONODE_DIR" JOURNEY_DIR="$FIXTURES" DRY_RUN=0 bash "$RUNNER" >/dev/null 2>&1 || EXIT_NONODE=$?
assert "missing node exits 0 (fail-open)" "[ '$EXIT_NONODE' -eq 0 ]"
# the runner must not need an external `dirname` before the node check: on CI a stripped PATH made it fall through to a missing installed os-config
# (OS_SERVICES_ENV unbound, exit 1; it passed on a Mac that has ~/.claude/scripts installed). Pin the shape and prove it with HOME pointed at nothing.
assert "runner does not call dirname before the node check" "! sed -n '1,/command -v node/p' '$RUNNER' | grep -v '^#' | grep -q 'dirname'"
EXIT_NOHOME=0
HOME="$FIXTURES/nohome" PATH="$NONODE_DIR" JOURNEY_DIR="$FIXTURES" DRY_RUN=0 bash "$RUNNER" >/dev/null 2>&1 || EXIT_NOHOME=$?
assert "missing node AND no installed copy of the OS: still exits 0 (fail-open)" "[ '$EXIT_NOHOME' -eq 0 ]"

# ---- test 8: findings schema — 9 required fields ----
run_monitor >/dev/null
if [ -f "$FINDINGS" ]; then
  assert "all findings have the 9-field schema" "python3 -c \"
import json
d=json.load(open('$FINDINGS'))
req={'repo','class','severity','file','line','title','detail','fix','autofixable'}
for f in d.get('findings',[]):
    missing = req - set(f)
    assert not missing, 'missing fields: %s in %s' % (missing, f)
\" 2>/dev/null"

  assert "autofixable is always False (propose-only)" "python3 -c \"
import json
d=json.load(open('$FINDINGS'))
for f in d.get('findings',[]):
    assert f.get('autofixable') is False, 'autofixable must be False: %s' % f
\" 2>/dev/null"
fi

echo ""
echo "journey-monitor: $_pass passed, $_fail failed"
[ "$_fail" -eq 0 ] || exit 1
