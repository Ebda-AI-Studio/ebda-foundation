#!/usr/bin/env bash
# Test os-selftest.sh — deterministic, offline-safe, fail-open tests.
# Covers: round-trip normalize, stale-job detection, orphan detection, fail-open
# behaviour when gh / launchctl / log files are absent.
# Run: bash ops/lib/__tests__/os-selftest.test.sh
set -euo pipefail

SELFTEST="$(cd "$(dirname "$0")/../../" && pwd)/os-selftest.sh"
NORMALIZE="$(cd "$(dirname "$0")/.." && pwd)/findings-normalize.py"
LAUNCHD="$(cd "$(dirname "$0")/../../" && pwd)/launchd"

_pass=0; _fail=0

assert_py() {
  local label="$1" pycode="$2"
  if python3 - <<PY
${pycode}
PY
  then echo "PASS: $label"; _pass=$((_pass + 1))
  else echo "FAIL: $label"; _fail=$((_fail + 1)); fi
}

assert_bash() {
  local label="$1"; shift
  if "$@"; then
    echo "PASS: $label"; _pass=$((_pass + 1))
  else
    echo "FAIL: $label"; _fail=$((_fail + 1))
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Prerequisite: os-selftest.sh and findings-normalize.py exist
# ─────────────────────────────────────────────────────────────────────────────
assert_bash "os-selftest.sh exists on disk" test -f "$SELFTEST"
assert_bash "findings-normalize.py exists on disk" test -f "$NORMALIZE"

# ─────────────────────────────────────────────────────────────────────────────
# Test 1: bash syntax check (no execution)
# ─────────────────────────────────────────────────────────────────────────────
assert_bash "os-selftest.sh passes bash -n syntax check" bash -n "$SELFTEST"

# ─────────────────────────────────────────────────────────────────────────────
# Test 2: DRY_RUN=1 run exits 0 (fail-open guarantee)
# The script must NEVER exit non-zero even when checks fail.
# ─────────────────────────────────────────────────────────────────────────────
assert_bash "DRY_RUN=1 exits 0 (fail-open)" bash -c "DRY_RUN=1 bash '$SELFTEST' 2>/dev/null"

# ─────────────────────────────────────────────────────────────────────────────
# Test 3: Round-trip — 3 synthetic findings → 2 grouped (grouping proof)
# ─────────────────────────────────────────────────────────────────────────────
WORK="$(mktemp -d /tmp/os-selftest-test-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

SYNTH="$WORK/synth.json"
python3 - "$SYNTH" <<'PY'
import json, sys
findings = [
    {"repo":"r","class":"synthetic","severity":"low","file":"a","line":1,
     "title":"alpha probe","detail":"d","fix":"f","autofixable":False},
    {"repo":"r","class":"synthetic","severity":"low","file":"b","line":2,
     "title":"alpha probe","detail":"d2","fix":"f","autofixable":False},
    {"repo":"r","class":"synthetic","severity":"medium","file":"c","line":3,
     "title":"beta probe","detail":"d3","fix":"f","autofixable":False},
]
json.dump(findings, open(sys.argv[1],'w'))
PY

NORM_OUT=$(python3 "$NORMALIZE" "$SYNTH" --json 2>/dev/null)

assert_py "round-trip: 3 raw findings normalize to exactly 2 groups" "
import json
result = json.loads('''${NORM_OUT}''')
counts = result.get('counts', {})
grouped = result.get('grouped', [])
assert counts.get('raw') == 3, 'raw != 3: %s' % counts
assert counts.get('grouped') == 2, 'grouped != 2: %s' % counts
assert any(g.get('count',1) == 2 for g in grouped), 'no group with count=2: %s' % grouped
"

assert_py "round-trip: grouped list contains class=synthetic only" "
import json
result = json.loads('''${NORM_OUT}''')
for g in result.get('grouped', []):
    assert g.get('class') == 'synthetic', 'unexpected class: %s' % g
"

# ─────────────────────────────────────────────────────────────────────────────
# Test 4: Stale-job scenario — a daily job whose log is 8 days old is stale.
#
# This test USED TO reimplement the check in python (`cadence_sec = 86400;
# window_sec = cadence_sec * 2 + 3600`) and then assert that the copy behaved —
# green no matter what os-selftest.sh actually did, and describing a formula the
# shipped code no longer contains. The decision now lives in
# lib/job-freshness.sh, so drive the REAL function.
#
# Deeper cadence coverage (monthly, weekly, arrays, daemons, the state-log
# allowlist) lives in lib/__tests__/job-cadence.test.sh alongside the library.
# ─────────────────────────────────────────────────────────────────────────────
# shellcheck source=../job-freshness.sh
. "$(cd "$(dirname "$0")/.." && pwd)/job-freshness.sh"

FAKE_LAUNCHD="$WORK/launchd"
FAKE_LOG="$WORK/forceai-fake-job.log"
FAKE_STATE="$WORK/state"
mkdir -p "$FAKE_LAUNCHD" "$FAKE_STATE"
NOW_T=$(date +%s)
export JF_WAKE_EPOCH_OVERRIDE=0   # verdicts must not depend on this host's last wake

# age_log <path> <seconds-ago> — deterministic "now" without waiting.
age_log() {
  AL_P="$1" AL_A="$2" python3 -c '
import os, time
p = os.environ["AL_P"]; t = time.time() - int(os.environ["AL_A"])
os.utime(p, (t, t))'
}
# jf_verdict <job> -> the verdict word for a fabricated plist
jf_verdict() {
  job_freshness_verdict "$FAKE_LAUNCHD/com.ebda.os.$1.plist" "$NOW_T" "$FAKE_STATE" "$FAKE_LAUNCHD" \
    | cut -d'|' -f1
}

# Build a plist that points at the log (daily schedule)
python3 - "$FAKE_LAUNCHD/com.ebda.os.fake-job.plist" "$FAKE_LOG" <<'PY'
import plistlib, sys
d = {
    'Label': 'com.ebda.os.fake-job',
    'ProgramArguments': ['/bin/bash', '/nonexistent/fake-job.sh'],
    'StartCalendarInterval': {'Hour': 8, 'Minute': 0},
    'StandardOutPath': sys.argv[2],
    'StandardErrorPath': sys.argv[2],
}
with open(sys.argv[1], 'wb') as fh:
    plistlib.dump(d, fh)
PY

printf 'x\n' > "$FAKE_LOG"; age_log "$FAKE_LOG" $(( 8 * 86400 ))
assert_bash "stale-job detection: a daily job with an 8-day-old log is stale" \
  test "$(jf_verdict fake-job)" = "stale"

# ─────────────────────────────────────────────────────────────────────────────
# Test 5: Orphan guard — fail-open when gh is absent (no crash, exit 0)
# We verify the detection logic exits 0 even without gh.
# ─────────────────────────────────────────────────────────────────────────────
assert_bash "orphan guard fail-open: exits 0 when PATH has no gh" \
  bash -c "DRY_RUN=1 PATH=/usr/bin:/bin bash '$SELFTEST' 2>/dev/null"

# ─────────────────────────────────────────────────────────────────────────────
# Test 6: Missing normalize library → exits 0 (fail-open) + round-trip reports broken
# We test the normalize-missing branch by pointing NORMALIZE_LIB at /dev/null
# ─────────────────────────────────────────────────────────────────────────────
# Patch a copy of os-selftest.sh with a nonexistent normalize path, run it, check exit 0
PATCHED="$WORK/os-selftest-patched.sh"
sed 's|NORMALIZE_LIB="./lib/findings-normalize.py"|NORMALIZE_LIB="/nonexistent/findings-normalize.py"|' \
  "$SELFTEST" > "$PATCHED" 2>/dev/null || cp "$SELFTEST" "$PATCHED"
chmod +x "$PATCHED"

assert_bash "missing normalize lib: exits 0 (fail-open)" \
  bash -c "DRY_RUN=1 bash '$PATCHED' 2>/dev/null"

# ─────────────────────────────────────────────────────────────────────────────
# Test 7: plist freshness — a just-written log is accepted, and the window comes
# from the job's OWN cadence rather than a flat guess.
#
# Also reimplemented the window in python before; it now drives the real
# function, and the negative control below proves the check can still fail.
# ─────────────────────────────────────────────────────────────────────────────
printf 'ok\n' > "$FAKE_LOG"; age_log "$FAKE_LOG" 60
assert_bash "fresh-log detection: a just-written log is accepted as fresh" \
  test "$(jf_verdict fake-job)" = "fresh"

# A daily job one hour past its slot is LATE, not broken — it must stay fresh.
age_log "$FAKE_LOG" 90000
assert_bash "a daily job 25h since its last run is still fresh" \
  test "$(jf_verdict fake-job)" = "fresh"

# NEGATIVE CONTROL: the same job, same code path, must go stale once its log
# genuinely stops moving. A freshness check that cannot report "stale" is the
# gate this whole file exists to catch.
age_log "$FAKE_LOG" 400000
assert_bash "negative control: the same job goes stale when its log stops moving" \
  test "$(jf_verdict fake-job)" = "stale"

# ─────────────────────────────────────────────────────────────────────────────
# Test 8: Full DRY_RUN run produces human digest with expected markers
# ─────────────────────────────────────────────────────────────────────────────
RUN_OUT=$(DRY_RUN=1 bash "$SELFTEST" 2>/dev/null)

assert_py "full run: output contains OS SELF-TEST RESULTS header" "
assert 'OS SELF-TEST RESULTS' in '''${RUN_OUT}''', 'missing header in output'
"

assert_py "full run: output contains PASS/FAIL counters" "
import re
assert re.search(r'PASS:\s*\d+', '''${RUN_OUT}'''), 'no PASS counter'
assert re.search(r'FAIL:\s*\d+', '''${RUN_OUT}'''), 'no FAIL counter'
"

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "os-selftest: $_pass passed, $_fail failed"
[ "$_fail" -eq 0 ] || exit 1
