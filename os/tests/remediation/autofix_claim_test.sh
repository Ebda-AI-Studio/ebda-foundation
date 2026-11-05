. "$(dirname "$0")/assert.sh"
export WHISKY_STATE_DIR="$(mktemp -d)"
. "$(dirname "$0")/../../ops/lib/autofix-coord.sh"
assert_eq "0" "$(autofix_claim_gate Ebda-AI-Studio/x deadbeef autofix; echo $?)" "free -> proceed (0)"
# a live babysit session owns the same ci: item
. "$(dirname "$0")/../../ops/lib/work-registry.sh"
wr_release 'ci:Ebda-AI-Studio/x@deadbeef' autofix   # release autofix's own claim from the call above
wr_claim 'ci:Ebda-AI-Studio/x@deadbeef' babysit-3 >/dev/null
assert_eq "1" "$(autofix_claim_gate Ebda-AI-Studio/x deadbeef autofix; echo $?)" "owned by session -> skip (1)"
wr_release 'ci:Ebda-AI-Studio/x@deadbeef' babysit-3
# ci:/pr key reconciliation: a live babysit session owns the pr: item for a PR;
# auto-fix must gate on the SAME canonical key when a PR exists for that sha.
wr_claim 'pr:o/r#5' babysit-3 >/dev/null
assert_eq "1" "$(autofix_claim_gate o/r somesha autofix 5; echo $?)" "PR owned by session -> skip via pr: key (1)"
wr_release 'pr:o/r#5' babysit-3
# with no prnum it still gates on the plain ci: key (free -> proceed)
assert_eq "0" "$(autofix_claim_gate o/r somesha autofix; echo $?)" "no prnum -> gates on ci: key (0)"
wr_release 'ci:o/r@somesha' autofix
rm -rf "$WHISKY_STATE_DIR"
report
