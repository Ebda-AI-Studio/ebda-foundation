. "$(dirname "$0")/assert.sh"
export WHISKY_STATE_DIR="$(mktemp -d)"
. "$(dirname "$0")/../../ops/remediation/approve.sh"

# --- parse_process_it ---
assert_eq "77"  "$(parse_process_it 'process it #77')"  "parses '#77'"
assert_eq "88"  "$(parse_process_it '  process   it   88  ')" "parses spaced, no hash"
assert_eq ""    "$(parse_process_it 'process everything')" "non-match -> empty"
assert_eq ""    "$(parse_process_it '/status')" "unrelated command -> empty"

# --- approve_pr: dry-run moves pending -> queue, no drain ---
pending_add 77 '{"pr":"77","slug":"o/r","branch":"b","repo":"/p"}'
out="$(REMEDIATE_DRYRUN=1 approve_pr 77)"
assert_contains "APPROVED pr#77" "$out" "approve reports APPROVED"
assert_eq "1" "$(queue_depth)" "approved item moved into the queue"
assert_eq "" "$(pending_get 77)" "approved item removed from pending"
out2="$(REMEDIATE_DRYRUN=1 approve_pr 999)"
assert_contains "NOPENDING pr#999" "$out2" "approving unknown pr -> NOPENDING"
rm -rf "$WHISKY_STATE_DIR"
report
