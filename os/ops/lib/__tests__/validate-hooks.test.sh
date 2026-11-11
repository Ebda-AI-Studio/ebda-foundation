#!/usr/bin/env bash
# validate-hooks.sh must FAIL on what is provably broken and only WARN on what it
# merely does not recognise. Both halves matter: a validator that fails on unknown
# keys reds every harness upgrade and gets switched off.
# Run: bash ops/lib/__tests__/validate-hooks.test.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/validate-hooks.sh"
SCHEMA="$(cd "$ROOT/.." && pwd)/schemas/hooks.schema.json"
_pass=0; _fail=0
ok() { echo "PASS: $1"; _pass=$((_pass+1)); }
no() { echo "FAIL: $1"; _fail=$((_fail+1)); }

H="$(mktemp -d)"; BIN="$H/real.sh"; printf '#!/bin/bash\nexit 0\n' > "$BIN"; chmod +x "$BIN"
NOEXEC="$H/noexec.sh"; printf '#!/bin/bash\n' > "$NOEXEC"; chmod 644 "$NOEXEC"
run() { bash "$SCRIPT" --settings "$1" --schema "$SCHEMA" >/dev/null 2>&1; }
# NOTE: `runout "$S" | grep -q ...` is WRONG under `set -o pipefail` — the
# validator exits 1 on a finding, so the whole pipeline exits 1 even when grep
# matched, and the assertion fails for the wrong reason. Capture, then grep.
# (feedback-pipefail-grep-q-sigpipe-flips-negated-test)
runout() { bash "$SCRIPT" --settings "$1" --schema "$SCHEMA" 2>&1 || true; }
saw()    { printf '%s' "$2" | grep -q "$1"; }
write() { python3 -c "import json,sys;open(sys.argv[1],'w').write(sys.argv[2])" "$1" "$2"; }

S="$H/s.json"

write "$S" "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"$BIN\"}]}]}}"
run "$S" && ok "a valid config passes" || no "a valid config passes"

write "$S" "{\"hooks\":{\"Stpo\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"$BIN\"}]}]}}"
run "$S" && no "unknown EVENT name fails" || ok "unknown EVENT name fails"
out="$(runout "$S")"; saw "unknown event" "$out" && ok "names the unknown event" || no "names the unknown event"

write "$S" "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"$H/gone.sh\"}]}]}}"
run "$S" && no "nonexistent command path fails" || ok "nonexistent command path fails"
out="$(runout "$S")"; saw "does NOT exist" "$out" && ok "names the missing path" || no "names the missing path"

write "$S" "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"$NOEXEC\"}]}]}}"
run "$S" && no "non-executable command fails" || ok "non-executable command fails"

write "$S" "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\"}]}]}}"
run "$S" && no "missing command key fails" || ok "missing command key fails"

write "$S" "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"webhook\",\"command\":\"$BIN\"}]}]}}"
run "$S" && no "wrong hook type fails" || ok "wrong hook type fails"

# unrecognised keys WARN but do not fail — `async` is real, and more will follow
write "$S" "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"$BIN\",\"async\":true}]}]}}"
run "$S" && ok "a known-but-newer key (async) passes" || no "a known-but-newer key (async) passes"
write "$S" "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"$BIN\",\"futureOption\":1}]}]}}"
run "$S" && ok "an unrecognised key passes" || no "an unrecognised key passes"
out="$(runout "$S")"; saw "unrecognised key" "$out" && ok "but it is reported as a warning" || no "but it is reported as a warning"

# empty / missing / unparseable are FINDINGS, not passes
write "$S" '{"hooks":{}}'
run "$S" && no "empty hooks block is a finding" || ok "empty hooks block is a finding"
printf 'not json' > "$S"
bash "$SCRIPT" --settings "$S" --schema "$SCHEMA" >/dev/null 2>&1; rc=$?
[ "$rc" = "2" ] && ok "unparseable settings exits 2" || no "unparseable settings exits 2 (got $rc)"
bash "$SCRIPT" --settings "$H/absent.json" --schema "$SCHEMA" >/dev/null 2>&1; rc=$?
[ "$rc" = "2" ] && ok "absent settings exits 2" || no "absent settings exits 2 (got $rc)"

rm -rf "$H"
echo; echo "validate-hooks: $_pass passed, $_fail failed"
[ "$_fail" -eq 0 ]
