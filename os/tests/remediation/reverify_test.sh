#!/usr/bin/env bash
. "$(dirname "$0")/assert.sh"
BIN="$(mktemp -d)"; export PATH="$BIN:$PATH"
RV="$(dirname "$0")/../../ops/dispatch-reverify.sh"

# fake gh: check-runs shows a failure -> still failing
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in *check-runs*) echo "true";; *) echo "";; esac
EOF
chmod +x "$BIN/gh"
assert_eq "0" "$(bash "$RV" ci-failure '{"slug":"o/r","sha":"s"}'; echo $?)" "ci still failing -> act (0)"

cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
echo "false"
EOF
chmod +x "$BIN/gh"
assert_eq "1" "$(bash "$RV" ci-failure '{"slug":"o/r","sha":"s"}'; echo $?)" "ci green now -> resolved (1)"

# code-finding: present in findings file -> act; absent -> resolved
export WHISKY_STATE_DIR="$(mktemp -d)"; echo '[{"id":"F1"}]' > "$WHISKY_STATE_DIR/dream-findings.json"
assert_eq "0" "$(bash "$RV" code-finding '{"id":"F1"}'; echo $?)" "finding still open -> act"
assert_eq "1" "$(bash "$RV" code-finding '{"id":"GONE"}'; echo $?)" "finding cleared -> resolved"
rm -rf "$BIN" "$WHISKY_STATE_DIR"
report
