. "$(dirname "$0")/assert.sh"
export WHISKY_STATE_DIR="$(mktemp -d)"
. "$(dirname "$0")/../../ops/dispatch.sh"
mk() { printf '{"id":"%s","kind":"%s","ts":%s,"target":{"slug":"o/r","sha":"abc","pr":"5"}}' "$1" "$2" "${3:-1000}"; }

# fakes via env seams
export DISPATCH_REVERIFY='true'            # condition still true (exit 0)
# NOTE: dispatch.sh invokes $DISPATCH_ROUTE via plain word-splitting (no eval), so a
# quoted `bash -c '...' _` string does NOT survive re-quoting once word-split — it
# blows up as `bash: -c: ...: command not found`. Use a real executable script instead;
# it exercises the exact same "responder was invoked with <kind> <target-json>" behavior
# without weakening the assertion or touching dispatch_event's contract.
ROUTED="$(mktemp)"; ROUTE_SCRIPT="$(mktemp)"
cat > "$ROUTE_SCRIPT" <<EOF
#!/usr/bin/env bash
echo "\$1 \$2" >> "$ROUTED"
EOF
chmod +x "$ROUTE_SCRIPT"
export DISPATCH_ROUTE="$ROUTE_SCRIPT"
export NOW=1000 COOLDOWN_SECS=300

# happy path: claims + routes + releases
out="$(dispatch_event "$(mk e1 ci-failure)")"
assert_contains "HANDLED ci:o/r@abc via ci-failure" "$out" "fresh event -> handled"
assert_eq "0" "$([ -s "$ROUTED" ] && echo 0 || echo 1)" "responder was invoked"

# replay of same id -> DROP replay
assert_contains "DROP replay" "$(NOW=1010 dispatch_event "$(mk e1 ci-failure)")" "same id -> replay dropped"

# cooldown: different id, same work_id, within window -> COOLDOWN
assert_contains "COOLDOWN ci:o/r@abc" "$(NOW=1100 dispatch_event "$(mk e2 ci-failure)")" "same work_id within cooldown"

# already-claimed by another owner -> SKIP
. "$(dirname "$0")/../../ops/lib/work-registry.sh"
NOW=2000 wr_claim 'ci:o/r@abc' babysit-session-9 >/dev/null
assert_contains "SKIP ci:o/r@abc owned-by babysit-session-9" "$(NOW=2001 dispatch_event "$(mk e3 ci-failure)")" "claimed by live session -> skip"
wr_release 'ci:o/r@abc' babysit-session-9

# kill-switch -> NOTIFY-ONLY
touch "$WHISKY_STATE_DIR/AUTONOMY_OFF"
assert_contains "NOTIFY-ONLY" "$(NOW=3000 dispatch_event "$(mk e4 ci-failure)")" "kill switch -> notify only"
rm -f "$WHISKY_STATE_DIR/AUTONOMY_OFF"

# re-verify says resolved -> DROP resolved
export DISPATCH_REVERIFY='false'
assert_contains "DROP resolved" "$(NOW=4000 dispatch_event "$(mk e5 ci-failure)")" "self-resolved -> dropped"
rm -rf "$WHISKY_STATE_DIR" "$ROUTED" "$ROUTE_SCRIPT"
report
