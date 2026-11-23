#!/usr/bin/env bash
# alert-drill.sh: sends exactly one message through the notify primitive, records the proof, fails loud when undelivered.
# Uses a stub notify (never touches Telegram or the Keychain).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
D="$ROOT/os/ops/alert-drill.sh"
p=0; f=0; ok() { echo "PASS: $1"; p=$((p+1)); }; no() { echo "FAIL: $1"; f=$((f+1)); }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export ALERT_DRILL_LOG="$T/drill.log" ALERT_DRILL_NOTIFY="$T/notify.sh" CALLS="$T/calls"
stub() { printf '#!/bin/bash\necho "$@" >> "$CALLS"\n%s\n' "$1" > "$T/notify.sh"; }

stub 'echo "notify: sent (telegram ok:true message_id=4242)"'; rm -f "$CALLS" "$ALERT_DRILL_LOG"
out="$(bash "$D" 2>&1)"; rc=$?
[ $rc = 0 ] && printf '%s' "$out" | grep -q "DELIVERED.*path=telegram message_id=4242" && ok "telegram path: delivered with message id" || no "telegram path ($rc $out)"
[ "$(wc -l < "$CALLS" | tr -d " ")" = 1 ] && ok "exactly one message sent" || no "message count"
grep -q '"delivered":true,"path":"telegram","messageId":4242' "$ALERT_DRILL_LOG" && ok "record written (JSON line)" || no "record: $(cat "$ALERT_DRILL_LOG" 2>&1)"
grep -q "ALERT DRILL" "$CALLS" && grep -q "id=drill-" "$CALLS" && ok "message carries the drill id" || no "message body"

stub 'echo "notify: sent via brain"'; out="$(bash "$D" 2>&1)"; rc=$?
[ $rc = 0 ] && printf '%s' "$out" | grep -q "path=brain" && tail -n1 "$ALERT_DRILL_LOG" | grep -q '"path":"brain","messageId":null' && ok "brain fallback is reported as such" || no "brain path ($out)"

stub 'echo "notify: FAILED - both refused" >&2; exit 1'; out="$(bash "$D" 2>&1)"; rc=$?
[ $rc = 1 ] && printf '%s' "$out" | grep -q "NOT DELIVERED" && tail -n1 "$ALERT_DRILL_LOG" | grep -q '"delivered":false' && ok "undelivered: exit 1, recorded false" || no "failure path ($rc $out)"

stub 'echo "something unexpected"'; bash "$D" >/dev/null 2>&1; rc=$?
[ $rc = 1 ] && ok "exit 0 without a delivery line is NOT trusted" || no "false green ($rc)"

stub 'echo "notify: sent (telegram ok:true message_id=1)"'; rm -f "$CALLS"; n="$(wc -l < "$ALERT_DRILL_LOG")"
out="$(bash "$D" --dry-run 2>&1)"; rc=$?
[ $rc = 0 ] && [ ! -e "$CALLS" ] && [ "$(wc -l < "$ALERT_DRILL_LOG" | tr -d " ")" = "$(echo $n)" ] && ok "--dry-run sends nothing, records nothing" || no "dry-run ($out)"
bash "$D" --bogus >/dev/null 2>&1; [ $? = 2 ] && ok "unknown option exits 2" || no "usage"
echo "alert-drill: $p passed, $f failed"; [ "$f" = 0 ]
