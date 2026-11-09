. "$(dirname "$0")/assert.sh"
export WHISKY_STATE_DIR="$(mktemp -d)"     # ledger.sh honors this override
. "$(dirname "$0")/../../ops/remediation/ledger.sh"
# queue FIFO
queue_add 101; queue_add 102
assert_eq "2"   "$(queue_depth)" "depth 2"
assert_eq "101" "$(queue_pop)"   "FIFO pops 101 first"
assert_eq "1"   "$(queue_depth)" "depth 1 after pop"
queue_pop >/dev/null  # drain leftover 102 so the queue is empty
# queue carries per-PR JSON context (not just bare numbers)
queue_add '{"pr":"7","slug":"o/r","branch":"b","repo":"/p"}'
ctx_out="$(queue_pop)"
assert_contains '"pr":"7"'    "$ctx_out" "queue round-trips JSON context: pr field"
assert_contains '"slug":"o/r"' "$ctx_out" "queue round-trips JSON context: slug field"
# circuit breaker: 3 class-a allowed/hr, 4th blocked
NOW=1000000 cb_record class-a; NOW=1000001 cb_record class-a; NOW=1000002 cb_record class-a
assert_eq "1" "$(NOW=1000003 cb_allow class-a; echo $?)" "4th class-a in the hour is blocked"
# single-runner lock: second concurrent acquire fails fast
runner_lock sleep 2 & sleep 0.3
assert_eq "1" "$(runner_lock true; echo $?)" "runner busy -> lock refused"
wait
# stall
stall_bump k1; stall_bump k1; stall_bump k1
assert_eq "0" "$(stall_over k1; echo $?)" "k1 stalled after 3 cycles (>2)"
# pending-approval store: add -> get round-trips, pop returns + removes
pending_add 55 '{"pr":"55","slug":"o/r","branch":"remediate/x","repo":"/p"}'
assert_contains '"pr":"55"'  "$(pending_get 55)" "pending_get returns stored item"
assert_contains '"slug":"o/r"' "$(pending_pop 55)" "pending_pop returns stored item"
assert_eq ""  "$(pending_get 55)" "pending_pop removed the key"
assert_eq ""  "$(pending_pop 999)" "pending_pop of missing pr -> empty"
rm -rf "$WHISKY_STATE_DIR"
report
