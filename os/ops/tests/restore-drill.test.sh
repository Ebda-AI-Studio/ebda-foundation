#!/usr/bin/env bash
# restore-drill.sh (ruling F-I6): not configured = exit 3 (never a pass); PASS only on exit 0 + "PASS" + no "FAIL"; the result is
# POSTed to the brain /drill with the bearer token; an unreachable brain exits 10; DRY_RUN posts nothing. curl is faked.
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
[ -n "\${FAKE_CURL_FAIL:-}" ] && exit 22
for a in "\$@"; do case "\$a" in @*) cat "\${a#@}" >> "$T/curl.args";; esac; done
SH
chmod +x "$T/bin/curl"
run() { # cmd [extra env...]
  local cmd="$1"; shift
  : > "$T/curl.args"; : > "$T/curl.args"
  env HOME="$T/home" PATH="$T/bin:$PATH" EBDA_OS_LOCAL_ENV="$T/none.env" OS_SERVICES_ENV="$T/none" OS_BRAIN_URL=https://brain.test INGEST_TOKEN=tok OS_RESTORE_DRILL_CMD="$cmd" "$@" bash "$OPS/restore-drill.sh" >"$T/out" 2>&1
}
run "" ; rc=$?; env -u OS_RESTORE_DRILL_CMD HOME="$T/home" EBDA_OS_LOCAL_ENV="$T/none.env" OS_SERVICES_ENV="$T/none" bash "$OPS/restore-drill.sh" >"$T/out" 2>&1; rc=$?
{ [ "$rc" = 3 ] && grep -q "NOT CONFIGURED" "$T/out"; } && pass "no command configured -> exit 3, loud" || fail "unconfigured rc=$rc"
run 'echo restore ok; echo PASS'; rc=$?
{ [ "$rc" = 0 ] && grep -q '"result": "pass"' "$T/curl.args" && grep -q 'brain.test/drill' "$T/curl.args" && grep -q 'Authorization: Bearer tok' "$T/curl.args"; } && pass "PASS output -> posted as pass with the bearer token" || { fail "pass path rc=$rc"; cat "$T/out" "$T/curl.args" "$T/curl.args"; }
run 'echo restore ok'; rc=$?
{ [ "$rc" = 0 ] && grep -q '"result": "fail"' "$T/curl.args"; } && pass "exit 0 without the word PASS is a FAIL" || fail "no-PASS word"
run 'echo PASS; echo FAIL table x'; 
grep -q '"result": "fail"' "$T/curl.args" && pass "PASS and FAIL together is a FAIL" || fail "mixed output"
run 'echo PASS; exit 3'
grep -q '"result": "fail"' "$T/curl.args" && pass "non-zero exit is a FAIL even with PASS printed" || fail "exit code ignored"
run 'echo PASS' FAKE_CURL_FAIL=1; rc=$?
[ "$rc" = 10 ] && pass "unreachable brain -> exit 10 (result printed, not lost)" || fail "post failure rc=$rc"
run 'echo PASS' DRY_RUN=1; rc=$?
{ [ "$rc" = 0 ] && [ ! -s "$T/curl.args" ]; } && pass "DRY_RUN posts nothing" || fail "dry run posted"
echo "── $_pass passed, $_fail failed ──"
[ "$_fail" -eq 0 ]
