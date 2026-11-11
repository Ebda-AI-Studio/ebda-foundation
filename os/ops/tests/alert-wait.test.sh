#!/usr/bin/env bash
# alert-wait.sh (AIOS-8): baseline on first run (no replay), exits 0 printing only alerts newer than the stored id and advances it,
# --once exits 1 when nothing is new, a 401 exits 2, and the password never reaches the command line. curl is faked.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1; OPS="$(pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
_pass=0; _fail=0
pass() { echo "PASS: $1"; _pass=$((_pass+1)); }
fail() { echo "FAIL: $1"; _fail=$((_fail+1)); }
mkdir -p "$T/bin"
cat > "$T/bin/curl" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$T/curl.args"
out=""; url=""
while [ \$# -gt 0 ]; do case "\$1" in -o) shift; out="\$1";; http*) url="\$1";; esac; shift; done
since="\$(printf '%s' "\$url" | sed -n 's/.*since=\([0-9]*\).*/\1/p')"
code="\$(cat "$T/code")"
python3 -I - "\$since" "$T/db.json" > "\$out" <<'PY'
import json, sys
since = int(sys.argv[1] or 0)
db = json.load(open(sys.argv[2]))
print(json.dumps({"alerts": sorted([a for a in db if a["id"] > since], key=lambda a: -a["id"])}))
PY
printf '%s' "\$code"
SH
chmod +x "$T/bin/curl"
echo '[{"id":7,"source":"ebda-store/api","level":"p1","title":"old one","text":"old","at":1794300000000,"count":1}]' > "$T/db.json"
echo 200 > "$T/code"
run() { : > "$T/curl.args"; env PATH="$T/bin:$PATH" EBDA_OS_DASH_PASSWORD=sekret OS_BRAIN_URL=https://brain.test EBDA_OS_LOCAL_ENV="$T/none" bash "$OPS/alert-wait.sh" --state "$T/last" --interval 1 "$@" >"$T/out" 2>"$T/err"; }

run --once; rc=$?
{ [ "$rc" = 1 ] && [ "$(cat "$T/last")" = 7 ] && ! grep -q 'old one' "$T/out"; } && pass "first run: baseline #7, history not replayed (must not fire)" || { fail "baseline rc=$rc"; cat "$T/out" "$T/err"; }
grep -q sekret "$T/curl.args" && fail "password on the curl command line" || pass "password never on the command line"

echo '[{"id":7,"source":"ebda-store/api","level":"p1","title":"old one","text":"old","at":1794300000000,"count":1},{"id":8,"source":"ebda-store/api","level":"p1","title":"Ebda Store nightly backup sweep FAILED","text":"sweep failed","at":1794360000000,"count":2},{"id":9,"source":"github/Ebda-AI-Studio/ebda-store","level":"p1","title":"CI failed on main","text":"CI failed","url":"https://github.com/x/actions/runs/1","at":1794360060000,"count":1}]' > "$T/db.json"
run; rc=$?
{ [ "$rc" = 0 ] && head -1 "$T/out" | grep -q '^#9 ' && grep -q '#8 .*backup sweep FAILED x2' "$T/out" && ! grep -q 'old one' "$T/out" && [ "$(cat "$T/last")" = 9 ]; } && pass "new alerts: printed newest first, only those after #7, state -> #9 (must fire)" || { fail "new alerts rc=$rc"; cat "$T/out" "$T/err"; }

run --once; rc=$?
[ "$rc" = 1 ] && pass "nothing new after #9: --once exits 1" || fail "nothing-new rc=$rc"

run --once --since 0; rc=$?
{ [ "$rc" = 0 ] && grep -q 'old one' "$T/out"; } && pass "--since 0 replays what the brain holds" || fail "--since 0 rc=$rc"

echo 401 > "$T/code"; rm -f "$T/last"
run --once; rc=$?
[ "$rc" = 2 ] && pass "401 exits 2" || fail "401 rc=$rc"

echo "alert-wait: $_pass passed, $_fail failed"
[ "$_fail" = 0 ]
