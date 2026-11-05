. "$(dirname "$0")/assert.sh"
bindir="$(mktemp -d)"
cat > "$bindir/claude" <<'EOF'
#!/usr/bin/env bash
echo '{"score":92,"reasoning":"lockfile-only, no runtime change"}'
EOF
chmod +x "$bindir/claude"
PATH="$bindir:$PATH"; . "$(dirname "$0")/../../ops/remediation/review-score.sh"
out="$(review_score 42 Ebda-AI-Studio/x)"
assert_contains '"score":92' "$out" "parses score from review"
# fail-closed: broken claude output -> score 0
cat > "$bindir/claude" <<'EOF'
#!/usr/bin/env bash
echo 'not json'
EOF
out2="$(review_score 42 Ebda-AI-Studio/x)"
assert_contains '"score":0' "$out2" "unparseable review -> fail-closed score 0"
rm -rf "$bindir"
report
