#!/usr/bin/env bash
# sync-foundation's convergence gate must read the GRAPH'S OWN built_at_commit,
# not just its own marker file. On 2026-09-04 the marker said the graph was current
# at 332a68ec while graph.json recorded 82e570c3 — 26 commits earlier — and the gate
# reported "current" on every run. A freshness check that consults its own
# bookkeeping instead of the artifact cannot detect the artifact going stale.
# Run: bash ops/lib/__tests__/sync-foundation-freshness.test.sh
set -uo pipefail
SRC="$(cd "$(dirname "$0")/../.." && pwd)/sync-foundation.sh"
_pass=0; _fail=0
ok() { echo "PASS: $1"; _pass=$((_pass+1)); }
no() { echo "FAIL: $1"; _fail=$((_fail+1)); }

grep -q "built_at_commit" "$SRC" && ok "the gate reads graph.json's built_at_commit" || no "the gate reads graph.json's built_at_commit"
grep -q 'graph_stale' "$SRC" && ok "a stale-graph condition exists" || no "a stale-graph condition exists"
grep -qE 'graph_stale.*=.*"0"' "$SRC" && ok "the 'current' branch requires graph_stale=0" || no "the 'current' branch requires graph_stale=0"

# the logic itself, extracted and exercised — marker fresh but graph behind must NOT be "current"
res=$(head_now=aaa; last_sync=aaa; src_drift=""; behind=0; graph_commit=bbb
  graph_stale=0; [ -n "$graph_commit" ] && [ "$graph_commit" != "$head_now" ] && graph_stale=1
  if [ "$head_now" = "$last_sync" ] && [ -z "$src_drift" ] && [ "$behind" = "0" ] && [ "$graph_stale" = "0" ]; then echo CURRENT; else echo REGEN; fi)
[ "$res" = "REGEN" ] && ok "marker fresh + graph behind -> REGEN (the live bug)" || no "marker fresh + graph behind -> REGEN (got $res)"

res=$(head_now=aaa; last_sync=aaa; src_drift=""; behind=0; graph_commit=aaa
  graph_stale=0; [ -n "$graph_commit" ] && [ "$graph_commit" != "$head_now" ] && graph_stale=1
  if [ "$head_now" = "$last_sync" ] && [ -z "$src_drift" ] && [ "$behind" = "0" ] && [ "$graph_stale" = "0" ]; then echo CURRENT; else echo REGEN; fi)
[ "$res" = "CURRENT" ] && ok "everything aligned -> CURRENT (no churn)" || no "everything aligned -> CURRENT (got $res)"

# a graph with no recorded commit must not be treated as stale forever
res=$(head_now=aaa; last_sync=aaa; src_drift=""; behind=0; graph_commit=""
  graph_stale=0; [ -n "$graph_commit" ] && [ "$graph_commit" != "$head_now" ] && graph_stale=1
  if [ "$head_now" = "$last_sync" ] && [ -z "$src_drift" ] && [ "$behind" = "0" ] && [ "$graph_stale" = "0" ]; then echo CURRENT; else echo REGEN; fi)
[ "$res" = "CURRENT" ] && ok "absent built_at_commit does not force endless regeneration" || no "absent built_at_commit does not force endless regeneration"

echo; echo "sync-foundation-freshness: $_pass passed, $_fail failed"
[ "$_fail" -eq 0 ]
