#!/usr/bin/env bash
# wc-event.sh must never write the hook payload body (tool_input, prompt/message
# text, or any other free-text field) into ~/.claude/logs/wc-event.log — that
# payload routinely carries live secrets (DATABASE_URLs, PATs, API keys) and
# unbounded logging of it grew the log to 240MB/264k lines before it was
# deleted on 2026-09-15. Only a one-line summary + safe structural identifiers
# (session_id/hook_event_name/tool_name) belong in the log. The log must also
# self-rotate so it can never regrow unbounded.
# Run: bash ops/lib/__tests__/wc-event.test.sh
set -uo pipefail
SCRIPT="$(cd "$(dirname "$0")/../.." && pwd)/wc-event.sh"
_pass=0; _fail=0
ok() { echo "PASS: $1"; _pass=$((_pass+1)); }
no() { echo "FAIL: $1"; _fail=$((_fail+1)); }

SECRET='sk-live-topsecretRAILWAYtoken1234567890'

run_event() {  # $1=home $2=event_type $3=json payload (stdin)
    printf '%s' "$3" | HOME="$1" bash "$SCRIPT" "$2" >/dev/null 2>&1
}

# 1. a payload carrying a secret-looking string produces a summary line, and
#    the secret never reaches the log.
H="$(mktemp -d)"
run_event "$H" "done" "{\"session_id\":\"sess-abc123\",\"hook_event_name\":\"Stop\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo $SECRET\"}}"
LOG="$H/.claude/logs/wc-event.log"
[ -f "$LOG" ] && ok "log file created" || no "log file created"
grep -q '^\[.*\] event=done pid=[0-9]* ppid=[0-9]* payload_bytes=[0-9]*' "$LOG" 2>/dev/null && ok "summary line written" || no "summary line written"
grep -q "$SECRET" "$LOG" 2>/dev/null && no "secret is absent from the log" || ok "secret is absent from the log"
grep -q '^\s*payload:' "$LOG" 2>/dev/null && no "no 'payload:' line at all" || ok "no 'payload:' line at all"
grep -q 'tool_input' "$LOG" 2>/dev/null && no "raw tool_input key is absent" || ok "raw tool_input key is absent"

# 2. safe identifiers (session_id, hook_event_name, tool_name) DO make it into
#    the summary line — they're the point of the log.
grep -q 'session_id=sess-abc123' "$LOG" 2>/dev/null && ok "session_id present in summary" || no "session_id present in summary"
grep -q 'hook_event_name=Stop' "$LOG" 2>/dev/null && ok "hook_event_name present in summary" || no "hook_event_name present in summary"
grep -q 'tool_name=Bash' "$LOG" 2>/dev/null && ok "tool_name present in summary" || no "tool_name present in summary"

# 3. pet-event JSON is still produced, with the right type + session_id, via
#    the atomic tmp->rename write (no stray .tmp files left behind).
EVENTS_DIR="$H/.claude/pet-events"
n_json=$(find "$EVENTS_DIR" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
[ "$n_json" = "1" ] && ok "exactly one pet-event JSON written" || no "exactly one pet-event JSON written (got $n_json)"
n_tmp=$(find "$EVENTS_DIR" -maxdepth 1 -name '*.tmp' 2>/dev/null | wc -l | tr -d ' ')
[ "$n_tmp" = "0" ] && ok "no leftover .tmp file (atomic rename happened)" || no "no leftover .tmp file"
jf="$(find "$EVENTS_DIR" -maxdepth 1 -name '*.json' 2>/dev/null | head -1)"
if command -v jq >/dev/null 2>&1 && [ -n "$jf" ]; then
    [ "$(jq -r .type < "$jf")" = "done" ] && ok "pet-event type=done" || no "pet-event type=done"
    [ "$(jq -r .session_id < "$jf")" = "sess-abc123" ] && ok "pet-event session_id correct" || no "pet-event session_id correct"
else
    no "jq available to check pet-event JSON contents"
fi
rm -rf "$H"

# 4. no payload on stdin at all (Notification/idle-style call) still logs a
#    clean summary line and never errors under `set -u`.
H="$(mktemp -d)"
: | HOME="$H" bash "$SCRIPT" "attention" >/tmp/wc-event-test-stderr.$$ 2>&1
rc=$?
[ "$rc" = "0" ] && ok "empty-stdin invocation exits 0" || no "empty-stdin invocation exits 0 (rc=$rc)"
grep -q 'event=attention' "$H/.claude/logs/wc-event.log" 2>/dev/null && ok "empty-stdin invocation still logs a summary" || no "empty-stdin invocation still logs a summary"
rm -f "/tmp/wc-event-test-stderr.$$"
rm -rf "$H"

# 5. rotation: a log already past the ~1MB cap gets rotated to .1 and
#    truncated before the new summary line is appended.
H="$(mktemp -d)"
mkdir -p "$H/.claude/logs"
LOG="$H/.claude/logs/wc-event.log"
head -c 1200000 /dev/zero | tr '\0' 'x' > "$LOG"   # > 1MB, well past the cap
run_event "$H" "working" '{"session_id":"rot-1"}'
[ -f "$LOG.1" ] && ok "rotation created wc-event.log.1" || no "rotation created wc-event.log.1"
new_size=$(stat -c %s "$LOG" 2>/dev/null || stat -f %z "$LOG" 2>/dev/null || echo -1)
[ "$new_size" -lt 1000 ] && ok "rotated log starts small again ($new_size bytes)" || no "rotated log starts small again (got $new_size bytes)"
grep -q 'event=working' "$LOG" 2>/dev/null && ok "new summary line lands in the fresh log" || no "new summary line lands in the fresh log"
rm -rf "$H"

# 6. a log well under the cap is left in place (no spurious rotation).
H="$(mktemp -d)"
mkdir -p "$H/.claude/logs"
LOG="$H/.claude/logs/wc-event.log"
echo "pre-existing small log line" > "$LOG"
run_event "$H" "thinking" '{}'
[ -f "$LOG.1" ] && no "small log is NOT rotated" || ok "small log is NOT rotated"
grep -q 'pre-existing small log line' "$LOG" 2>/dev/null && ok "pre-existing content survives when under the cap" || no "pre-existing content survives when under the cap"
rm -rf "$H"

echo; echo "wc-event: $_pass passed, $_fail failed"
[ "$_fail" -eq 0 ]
