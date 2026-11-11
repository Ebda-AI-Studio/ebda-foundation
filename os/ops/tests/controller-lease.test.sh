#!/usr/bin/env bash
# controller-lease.sh (HANDS-COORD): claim POSTs /leases with the bearer token, release DELETEs it, a 409 (held by another
# controller) exits 4, no brain config exits 10, a bad repo exits 2. curl is faked.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1; OPS="$(pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
_pass=0; _fail=0
pass() { echo "PASS: $1"; _pass=$((_pass+1)); }
fail() { echo "FAIL: $1"; _fail=$((_fail+1)); }
mkdir -p "$T/bin" "$T/home"
cat > "$T/bin/curl" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$T/curl.args"
for a in "\$@"; do case "\$a" in @*) cat "\${a#@}" >> "$T/curl.args"; echo >> "$T/curl.args";; esac; done
printf '%s\n%s' "\$(cat "$T/resp")" "\$(cat "$T/code")"
SH
chmod +x "$T/bin/curl"
run() { : > "$T/curl.args"; env HOME="$T/home" PATH="$T/bin:$PATH" EBDA_OS_LOCAL_ENV="$T/none.env" OS_SERVICES_ENV="$T/none" OS_BRAIN_URL=https://brain.test INGEST_TOKEN=tok OS_CONTROLLER_ID=session-1 bash "$OPS/controller-lease.sh" "$@" >"$T/out" 2>&1; }

echo '{"ok":true}' > "$T/resp"; echo 200 > "$T/code"
run claim Ebda-AI-Studio/ebda-store 60 "fixing CI"; rc=$?
{ [ "$rc" = 0 ] && grep -q -- '-X POST' "$T/curl.args" && grep -q 'brain.test/leases' "$T/curl.args" && grep -q 'Authorization: Bearer tok' "$T/curl.args" && grep -q '"holder": "session-1"' "$T/curl.args" && grep -q '"ttlMin": 60' "$T/curl.args"; } && pass "claim posts repo, holder, ttl with the bearer token" || { fail "claim rc=$rc"; cat "$T/out" "$T/curl.args"; }

echo '{"ok":false,"holder":"other"}' > "$T/resp"; echo 409 > "$T/code"
run claim Ebda-AI-Studio/ebda-store; rc=$?
[ "$rc" = 4 ] && pass "held by another controller exits 4 (must fire)" || fail "409 rc=$rc"

echo '{"released":true}' > "$T/resp"; echo 200 > "$T/code"
run release Ebda-AI-Studio/ebda-store; rc=$?
{ [ "$rc" = 0 ] && grep -q -- '-X DELETE' "$T/curl.args"; } && pass "release sends DELETE" || fail "release rc=$rc"

run claim 'not a repo'; rc=$?
{ [ "$rc" = 2 ] && [ ! -s "$T/curl.args" ]; } && pass "a bad repo exits 2 and calls nothing (must not fire)" || fail "bad repo rc=$rc"

env -u OS_BRAIN_URL -u INGEST_TOKEN HOME="$T/home" PATH="$T/bin:$PATH" EBDA_OS_LOCAL_ENV="$T/none.env" OS_SERVICES_ENV="$T/none" bash "$OPS/controller-lease.sh" claim o/r >"$T/out" 2>&1; rc=$?
[ "$rc" = 10 ] && pass "no brain config exits 10" || fail "no config rc=$rc"

echo "controller-lease: $_pass passed, $_fail failed"
[ "$_fail" = 0 ]
