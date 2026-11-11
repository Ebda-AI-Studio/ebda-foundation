#!/usr/bin/env bash
# atomic.sh + state-guard.sh. The load-bearing property is that a FAILED write
# leaves the previous content intact — that is the whole point, so it is asserted
# for every failure mode: producer dies, payload empty, transform blows up,
# existing file corrupt.
# Run: bash ops/lib/__tests__/atomic-state.test.sh
set -uo pipefail
LIB="$(cd "$(dirname "$0")/.." && pwd)"
_pass=0; _fail=0
ok() { echo "PASS: $1"; _pass=$((_pass+1)); }
no() { echo "FAIL: $1"; _fail=$((_fail+1)); }
# shellcheck source=/dev/null
. "$LIB/atomic.sh"
# shellcheck source=/dev/null
. "$LIB/state-guard.sh"

H="$(mktemp -d)"; F="$H/state.json"

# ---- atomic_write ----
printf '{"entries":[1]}\n' > "$F"
printf '{"entries":[1,2]}\n' | atomic_write "$F" && ok "atomic_write exits 0" || no "atomic_write exits 0"
grep -q '1,2' "$F" && ok "atomic_write replaced the content" || no "atomic_write replaced the content"

# producer dies -> target unchanged
( bash -c 'echo -n ""; exit 1' | atomic_write "$F" ) >/dev/null 2>&1
grep -q '1,2' "$F" && ok "failed producer leaves previous content" || no "failed producer leaves previous content"

# an empty payload is refused, not written
printf '' | atomic_write "$F" >/dev/null 2>&1 && no "empty payload refused" || ok "empty payload refused"
grep -q '1,2' "$F" && ok "empty payload did not truncate the target" || no "empty payload did not truncate the target"

# no temp litter
find "$H" -name '.*.tmp.*' | grep -q . && no "no temp files left behind" || ok "no temp files left behind"

# ---- atomic_json_update ----
atomic_json_update "$F" 'd["entries"].append(3)' && ok "atomic_json_update exits 0" || no "atomic_json_update exits 0"
python3 -c "import json;assert json.load(open('$F'))['entries']==[1,2,3]" && ok "transform applied" || no "transform applied"

# a transform that raises must leave the file untouched
atomic_json_update "$F" 'raise RuntimeError("boom")' >/dev/null 2>&1 && no "raising transform fails" || ok "raising transform fails"
python3 -c "import json;assert json.load(open('$F'))['entries']==[1,2,3]" && ok "raising transform left file intact" || no "raising transform left file intact"

# a transform producing non-JSON must be refused
atomic_json_update "$F" 'd = object()' >/dev/null 2>&1 && no "non-JSON result refused" || ok "non-JSON result refused"
python3 -c "import json;assert json.load(open('$F'))['entries']==[1,2,3]" && ok "non-JSON attempt left file intact" || no "non-JSON attempt left file intact"

# a CORRUPT existing file is refused, not silently replaced (it is evidence)
C="$H/corrupt.json"; echo 'not json' > "$C"
atomic_json_update "$C" 'd = {"x":1}' >/dev/null 2>&1 && no "corrupt input refused" || ok "corrupt input refused"
grep -q 'not json' "$C" && ok "corrupt file preserved as evidence" || no "corrupt file preserved as evidence"

# an ABSENT file is a legitimate create
N="$H/new.json"
atomic_json_update "$N" 'd = {"created": True}' && ok "absent file is created" || no "absent file is created"
python3 -c "import json;assert json.load(open('$N'))['created'] is True" && ok "created content correct" || no "created content correct"

# ---- state-guard ----
V="$H/guarded.json"
validator() { python3 -c "import json,sys;d=json.load(open(sys.argv[1]));sys.exit(0 if 'required_key' in d else 1)" "$1"; }
printf '{"required_key":"a"}\n' > "$V"
snapshot_state "$V" && ok "snapshot_state exits 0" || no "snapshot_state exits 0"
echo 'CORRUPT' > "$V"
validate_state "$V" validator >/dev/null 2>&1 && no "validate_state rejects corrupt" || ok "validate_state rejects corrupt"
restore_state "$V" && ok "restore_state exits 0" || no "restore_state exits 0"
grep -q 'required_key' "$V" && ok "restore_state brought back the good file" || no "restore_state brought back the good file"

# an EMPTY state file must fail validation, not read as 'no data'
snapshot_state "$V"; : > "$V"
validate_state "$V" validator >/dev/null 2>&1 && no "empty state fails validation" || ok "empty state fails validation"
restore_state "$V" >/dev/null

# valid output must NOT be rolled back
snapshot_state "$V"; printf '{"required_key":"c"}\n' > "$V"
validate_state "$V" validator >/dev/null 2>&1 && ok "valid state passes" || no "valid state passes"
grep -q '"c"' "$V" && ok "valid state not rolled back" || no "valid state not rolled back"

# progress detection: a timed-out cycle that still changed state keeps its work
state_changed_since_snapshot "$V" && ok "detects changed state" || no "detects changed state"
cp -p "$V" "$V.bak"
state_changed_since_snapshot "$V" && no "detects unchanged state" || ok "detects unchanged state"

# restore with no snapshot must fail loudly, not silently succeed
rm -f "$V.bak"
restore_state "$V" >/dev/null 2>&1 && no "restore without snapshot fails" || ok "restore without snapshot fails"

rm -rf "$H"
echo; echo "atomic-state: $_pass passed, $_fail failed"
[ "$_fail" -eq 0 ]
