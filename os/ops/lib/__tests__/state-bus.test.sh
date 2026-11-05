#!/usr/bin/env bash
# Test the state bus emitters: emit_event, emit_inbox, rotation, bad-detail resilience.
# Run: bash ops/lib/__tests__/state-bus.test.sh
#
# NOTE: _bus_rotate_events contains `prev="$(cat "$marker" 2>/dev/null)"`.
# In bash 3.2 under `set -e`, a command-substitution assignment whose subcommand
# exits non-zero causes the script to exit — so we pre-create $HOME/.whisky-os-state/.events-day
# before sourcing/calling the bus functions. See "Source bug" note in the test report.
set -euo pipefail

_pass=0
_fail=0

assert_py() {
  local label="$1" pycode="$2"
  if python3 - <<PY
${pycode}
PY
  then
    echo "PASS: $label"
    _pass=$((_pass + 1))
  else
    echo "FAIL: $label"
    _fail=$((_fail + 1))
  fi
}

# ---------------------------------------------------------------------------
# Fresh HOME for tests 1–5 (single events.ndjson accumulation, except rotation
# which gets its own HOME below).
# ---------------------------------------------------------------------------
HOME="$(mktemp -d)"; export HOME
STATEDIR="$HOME/.whisky-os-state"
mkdir -p "$STATEDIR"
# Pre-create the day marker (today) to avoid bash 3.2 set -e exit on missing file.
TODAY="$(date -u +%F)"
printf '%s' "$TODAY" > "$STATEDIR/.events-day"

. "$(dirname "$0")/../os-state.sh"

# ---------------------------------------------------------------------------
# TEST 1: emit_event writes 1 valid JSON line with severity==high and detail.a==1
# ---------------------------------------------------------------------------
emit_event "x" "high" "hi" '{"a":1}'
EVENTS_FILE="$STATEDIR/events.ndjson"

assert_py "emit_event writes 1 line, valid JSON, severity==high, detail.a==1" "
import json
lines = open('${EVENTS_FILE}').read().strip().splitlines()
assert len(lines) == 1, 'expected 1 line, got %d' % len(lines)
obj = json.loads(lines[0])
assert obj['severity'] == 'high', 'severity=%s' % obj['severity']
assert obj['detail']['a'] == 1, 'detail=%s' % obj['detail']
assert obj['summary'] == 'hi', 'summary=%s' % obj['summary']
assert obj['name'] == 'x', 'name=%s' % obj['name']
assert obj['ts'].endswith('Z'), 'ts=%s' % obj['ts']
"

# ---------------------------------------------------------------------------
# TEST 2: invalid severity is coerced to "info"
# ---------------------------------------------------------------------------
emit_event "y" "bogus" "bad sev"

assert_py "bogus severity is coerced to info" "
import json
lines = open('${EVENTS_FILE}').read().strip().splitlines()
# latest line is the bogus-severity event
obj = json.loads(lines[-1])
assert obj['severity'] == 'info', 'severity=%s' % obj['severity']
assert obj['name'] == 'y', 'name=%s' % obj['name']
"

# ---------------------------------------------------------------------------
# TEST 3: emit_inbox writes to zero-inbox.ndjson (spoken==false)
#          AND mirrors a line into events.ndjson (severity high)
# ---------------------------------------------------------------------------
INBOX_FILE="$STATEDIR/zero-inbox.ndjson"
EVENTS_BEFORE="$(wc -l < "${EVENTS_FILE}" | tr -d ' ')"
emit_inbox "msg"

assert_py "emit_inbox writes 1 line to zero-inbox.ndjson, spoken==false" "
import json
lines = open('${INBOX_FILE}').read().strip().splitlines()
assert len(lines) == 1, 'expected 1 inbox line, got %d' % len(lines)
obj = json.loads(lines[0])
assert obj['spoken'] == False, 'spoken=%s' % obj['spoken']
assert obj['summary'] == 'msg', 'summary=%s' % obj['summary']
assert 'ts' in obj, 'missing ts'
"

assert_py "emit_inbox mirrors line into events.ndjson with severity==high" "
import json
lines = open('${EVENTS_FILE}').read().strip().splitlines()
events_before = ${EVENTS_BEFORE}
assert len(lines) == events_before + 1, 'expected %d lines, got %d' % (events_before+1, len(lines))
obj = json.loads(lines[-1])
assert obj['severity'] == 'high', 'severity=%s' % obj['severity']
assert obj['summary'] == 'msg', 'summary=%s' % obj['summary']
"

# ---------------------------------------------------------------------------
# TEST 4: rotation — fresh HOME, set .events-day to a past date, emit, assert archive
# ---------------------------------------------------------------------------
HOME_ROT="$(mktemp -d)"; export HOME="$HOME_ROT"
STATEDIR_ROT="$HOME_ROT/.whisky-os-state"
mkdir -p "$STATEDIR_ROT"
PAST_DATE="2000-01-01"
# Pre-create day marker with a PAST date so _bus_rotate_events sees it (no cat-fail on missing file)
printf '%s' "$PAST_DATE" > "$STATEDIR_ROT/.events-day"
# Pre-populate events.ndjson so there is something to rotate
printf '{"ts":"fake","name":"old","severity":"low","summary":"old event","detail":{}}\n' > "$STATEDIR_ROT/events.ndjson"

emit_event "new-event" "medium" "after rotation"

ARCHIVE_FILE_ROT="$STATEDIR_ROT/events-${PAST_DATE}.ndjson"
EVENTS_FILE_ROT="$STATEDIR_ROT/events.ndjson"

assert_py "rotation creates events-<pastdate>.ndjson archive" "
import os
assert os.path.exists('${ARCHIVE_FILE_ROT}'), 'archive not found: ${ARCHIVE_FILE_ROT}'
"

assert_py "fresh events.ndjson holds only the new post-rotation line" "
import json
lines = open('${EVENTS_FILE_ROT}').read().strip().splitlines()
assert len(lines) == 1, 'expected 1 line after rotation, got %d' % len(lines)
obj = json.loads(lines[0])
assert obj['name'] == 'new-event', 'name=%s' % obj['name']
"

# ---------------------------------------------------------------------------
# TEST 5: malformed detail JSON does not crash, detail becomes {"raw":"not-json"}
#         (reuse the rotation HOME for isolation, restore main statedir)
# ---------------------------------------------------------------------------
emit_event "z" "low" "bad detail" "not-json"

assert_py "malformed detail JSON yields detail.raw == 'not-json'" "
import json
lines = open('${EVENTS_FILE_ROT}').read().strip().splitlines()
obj = json.loads(lines[-1])
assert obj['name'] == 'z', 'name=%s' % obj['name']
assert obj['detail'].get('raw') == 'not-json', 'detail=%s' % obj['detail']
"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "state-bus: $_pass passed, $_fail failed"
[ "$_fail" -eq 0 ] || exit 1
