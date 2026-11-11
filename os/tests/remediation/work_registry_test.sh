. "$(dirname "$0")/assert.sh"
export WHISKY_STATE_DIR="$(mktemp -d)"
. "$(dirname "$0")/../../ops/lib/work-registry.sh"

# free -> claim succeeds; second owner blocked; same owner re-claims (refresh)
assert_eq "0" "$(NOW=1000 wr_claim 'pr:o/r#1' alice; echo $?)" "free item -> alice claims"
assert_eq "1" "$(NOW=1001 wr_claim 'pr:o/r#1' bob; echo $?)"   "held by alice -> bob blocked"
assert_eq "0" "$(NOW=1002 wr_claim 'pr:o/r#1' alice; echo $?)" "same owner re-claims (refresh)"
assert_eq "alice" "$(NOW=1003 wr_owner 'pr:o/r#1')" "owner is alice"

# lease expires -> re-claimable by anyone (ttl 1800 from claimed_at 1002 -> expires 2802)
assert_eq "0" "$(NOW=3000 wr_claim 'pr:o/r#1' bob; echo $?)" "after TTL, bob claims the expired item"
assert_eq "bob" "$(NOW=3001 wr_owner 'pr:o/r#1')" "owner now bob"

# release by owner frees it; wr_owner empty
wr_release 'pr:o/r#1' bob
assert_eq "" "$(NOW=3002 wr_owner 'pr:o/r#1')" "released -> no owner"

# heartbeat extends only for the owner
NOW=4000 wr_claim 'svc:api' carol 100 >/dev/null
assert_eq "1" "$(NOW=4001 wr_heartbeat 'svc:api' dave; echo $?)" "non-owner heartbeat rejected"
assert_eq "0" "$(NOW=4050 wr_heartbeat 'svc:api' carol 100; echo $?)" "owner heartbeat ok"
assert_eq "carol" "$(NOW=4120 wr_owner 'svc:api')" "heartbeat kept carol past original 100s TTL"

# wr_gc drops expired entries, keeps live ones
NOW=5000 wr_claim 'ci:o/r@live' eve 5000 >/dev/null      # expires 10000
NOW=5000 wr_claim 'ci:o/r@dead' eve 10   >/dev/null      # expires 5010
NOW=6500 wr_gc
assert_eq "eve" "$(NOW=6500 wr_owner 'ci:o/r@live')" "wr_gc keeps live entry (well within its TTL... )"
assert_eq ""    "$(NOW=6500 wr_owner 'ci:o/r@dead')" "wr_gc dropped the expired entry"
rm -rf "$WHISKY_STATE_DIR"
report
