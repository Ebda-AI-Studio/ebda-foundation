#!/usr/bin/env bash
# os_local_list: reads a per-machine JSON list, falls back to defaults, logs once and stays quiet-on-stdout when the file is absent.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/os/ops/lib/os-config.sh"
p=0; f=0
ok() { echo "PASS: $1"; p=$((p+1)); }
no() { echo "FAIL: $1"; f=$((f+1)); }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export EBDA_OS_LOCAL_JSON="$T/local.json"

out="$(os_local_list repos 2>"$T/err")"
{ [ -z "$out" ] && [ "$(wc -l <"$T/err" | tr -d ' ')" = 1 ]; } && ok "absent file: empty stdout, exactly one log line" || no "absent file behaviour ($out)"
out="$(os_local_list repos a b 2>"$T/err")"
{ [ "$out" = "$(printf 'a\nb')" ] && [ ! -s "$T/err" ]; } && ok "absent file + defaults: defaults, no log" || no "defaults not returned"

printf '{"repos":["x","y z"," "],"other":"notalist"}' > "$EBDA_OS_LOCAL_JSON"
out="$(os_local_list repos d 2>/dev/null)"
[ "$out" = "$(printf 'x\ny z')" ] && ok "present key overrides defaults, blanks dropped" || no "present key ($out)"
out="$(os_local_list missing d 2>/dev/null)"
[ "$out" = "d" ] && ok "missing key falls back to defaults" || no "missing key ($out)"
out="$(os_local_list other 2>/dev/null)"
[ -z "$out" ] && ok "non-list value yields nothing" || no "non-list value ($out)"
printf '{broken' > "$EBDA_OS_LOCAL_JSON"
out="$(os_local_list repos d 2>/dev/null)"; rc=$?
{ [ "$out" = "d" ] && [ "$rc" = 0 ]; } && ok "malformed JSON falls back, rc 0" || no "malformed JSON ($out rc=$rc)"
echo "os-local-list: $p passed, $f failed"; [ "$f" = 0 ]
