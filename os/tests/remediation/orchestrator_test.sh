. "$(dirname "$0")/assert.sh"
export WHISKY_STATE_DIR="$(mktemp -d)"; export REMEDIATE_DRYRUN=1
f="$WHISKY_STATE_DIR/f.json"
cat > "$f" <<'JSON'
[{"repo":"x","class":"lockfile-drift","severity":"low"},
 {"repo":"x","class":"rls-policy","severity":"high"},
 {"repo":"x","class":"graph-pending","severity":"low"},
 {"repo":"x","class":"code-health","severity":"medium"}]
JSON
out="$(bash "$(dirname "$0")/../../ops/remediate.sh" "$f")"
assert_contains "CLASS_A lockfile-drift"  "$out" "lockfile routed to Class-A PR"
assert_contains "EXCLUDED rls-policy"     "$out" "rls skipped as excluded"
assert_contains "OPERATIONAL graph-pending" "$out" "graphify run operationally"
assert_contains "CLASS_B code-health"     "$out" "code-health routed to Class-B (dry-run)"

# --approve <pr>: enqueue a Telegram-approved oversize fix (dry -> no drain)
. "$(dirname "$0")/../../ops/remediation/approve.sh"   # pending_add / queue_depth in this shell
pending_add 77 '{"pr":"77","slug":"Ebda-AI-Studio/x","branch":"remediate/x","repo":"/tmp/x"}'
aout="$(REMEDIATE_DRYRUN=1 bash "$(dirname "$0")/../../ops/remediate.sh" --approve 77)"
assert_contains "APPROVED pr#77" "$aout" "--approve moves the pending fix into the queue"
assert_eq "1" "$(queue_depth)" "approved fix is queued for the gate"
assert_eq "" "$(pending_get 77)" "approved fix removed from pending"

# coordination: a finding already claimed by a live session is skipped by remediate
. "$(dirname "$0")/../../ops/lib/work-registry.sh"
cat > "$f" <<'JSON'
[{"repo":"x","class":"code-health","id":"F1","severity":"medium"}]
JSON
wr_claim 'finding:F1' live-session-7 >/dev/null
cout="$(REMEDIATE_DRYRUN=1 bash "$(dirname "$0")/../../ops/remediate.sh" "$f")"
assert_contains "SKIP code-health (claimed)" "$cout" "claimed finding -> remediate skips it"
wr_release 'finding:F1' live-session-7

rm -rf "$WHISKY_STATE_DIR"
report
