. "$(dirname "$0")/assert.sh"
. "$(dirname "$0")/../../ops/remediation/gate.sh"
assert_eq "MERGE" "$(gate_decision success 0 88)" "green+clean+88 -> merge"
assert_eq "HUMAN" "$(gate_decision success 0 79)" "score 79 -> human"
assert_eq "HUMAN" "$(gate_decision failure 0 95)" "red CI -> human"
assert_eq "HUMAN" "$(gate_decision success 1 95)" "blast-radius dirty -> human"

# ci_state <rc> <out> -> success|failure (fail-closed)
assert_eq "success" "$(ci_state 0 'lint  pass')" "rc0 + non-empty pass output -> success"
assert_eq "failure" "$(ci_state 8 '')" "rc8 (pending/nonzero) -> failure"
assert_eq "failure" "$(ci_state 0 '')" "rc0 but empty output -> fail-closed failure"
assert_eq "failure" "$(ci_state 1 'x fail')" "rc1 with fail marker -> failure"
assert_eq "failure" "$(ci_state 0 'checks: cancelled')" "rc0 but bad terminal state -> failure"

# changes_only_lockfile <repo> <base> <head> -> exit 0 iff ONLY package-lock.json differs
TMP_REPO="$(mktemp -d)"
git -C "$TMP_REPO" init -q
git -C "$TMP_REPO" config user.email "test@example.com"
git -C "$TMP_REPO" config user.name "Test"
echo '{"name":"x"}' > "$TMP_REPO/package.json"
echo '{"lockfileVersion":1}' > "$TMP_REPO/package-lock.json"
git -C "$TMP_REPO" add package.json package-lock.json
git -C "$TMP_REPO" commit -q -m base
git -C "$TMP_REPO" branch base
echo '{"lockfileVersion":2}' > "$TMP_REPO/package-lock.json"
git -C "$TMP_REPO" add package-lock.json
git -C "$TMP_REPO" commit -q -m "lockfile only"
if changes_only_lockfile "$TMP_REPO" base HEAD; then _cl_rc=0; else _cl_rc=1; fi
assert_eq "0" "$_cl_rc" "lockfile-only change -> clean (exit 0)"

echo 'console.log(1)' > "$TMP_REPO/app.js"
git -C "$TMP_REPO" add app.js
git -C "$TMP_REPO" commit -q -m "add code file"
if changes_only_lockfile "$TMP_REPO" base HEAD; then _cl_rc2=0; else _cl_rc2=1; fi
assert_eq "1" "$_cl_rc2" "code file changed too -> dirty (exit 1)"

rm -rf "$TMP_REPO"

report
