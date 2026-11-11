#!/usr/bin/env bash
# Regression test for ops/graphify-merge-chunks.sh.
#
# The bug this locks down (found 2026-09-02): edges were keyed on e["type"],
# but graphify edges carry "relation" — so the third element of every key was
# None, the `None in k` guard fired on all of them, and the merge silently
# added ZERO edges on every run since it was written. Compounding it, the graph
# was read/written at g["edges"] while NetworkX node-link format keeps the edge
# list at g["links"], so anything that did survive went to a key nothing reads.
#
# Run: bash ops/lib/__tests__/graphify-merge-chunks.test.sh
set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")/../.." && pwd)/graphify-merge-chunks.sh"
_pass=0; _fail=0
ok() { echo "PASS: $1"; _pass=$((_pass+1)); }
no() { echo "FAIL: $1"; _fail=$((_fail+1)); }

W="$(mktemp -d)"; GO="$W/graphify-out"; mkdir -p "$GO"

# graph in the real NetworkX node-link shape: edges under "links", not "edges"
cat > "$GO/graph.json" <<'JSON'
{ "directed": true, "multigraph": false, "graph": {},
  "nodes": [ {"id":"existing_a","label":"A","source_file":"/m/a.md"} ],
  "links": [ {"source":"existing_a","target":"existing_a","relation":"references"} ],
  "hyperedges": [] }
JSON

# chunk: 2 new nodes, 3 edges — one duplicate of an existing link, one with no
# relation at all (legal), one missing an endpoint (must be dropped)
cat > "$GO/.graphify_polish_chunk_test.json" <<'JSON'
{ "nodes": [ {"id":"new_b","label":"B","source_file":"/m/b.md"},
             {"id":"no_src","label":"NoSource"} ],
  "edges": [ {"source":"new_b","target":"existing_a","relation":"describes"},
             {"source":"existing_a","target":"existing_a","relation":"references"},
             {"source":"new_b","target":"existing_a"},
             {"source":"new_b"} ] }
JSON

OUT="$(bash "$SCRIPT" "$W" 2>&1)" || true
echo "$OUT" | sed 's/^/    /'

python3 - "$GO/graph.json" <<'PY' && ok "edges merged into links, deduped, endpoint-guarded" || no "edge merge behaviour"
import json,sys
g=json.load(open(sys.argv[1]))
assert "edges" not in g, 'a stray "edges" key was written back'
L=g["links"]
k=lambda e:(e.get("source"),e.get("target"),e.get("relation"))
assert ("new_b","existing_a","describes") in {k(e) for e in L}, "new edge not merged"
assert ("new_b","existing_a",None) in {k(e) for e in L}, "relation-less edge wrongly dropped"
assert len([e for e in L if k(e)==("existing_a","existing_a","references")])==1, "duplicate not deduped"
assert not any(e.get("target") is None for e in L), "edge without endpoints was merged"
assert len(L)==3, f"expected 3 links, got {len(L)}"
assert {n["id"] for n in g["nodes"]}=={"existing_a","new_b"}, "node set wrong (no_src must drop)"
PY

echo "$OUT" | grep -q '+1 nodes, +2 edges' && ok "reports the real edge count" || no "reports the real edge count (got: $(echo "$OUT" | tail -1))"
echo "$OUT" | grep -q 'dropped(no endpoints) 1' && ok "reports endpoint-dropped edges" || no "reports endpoint-dropped edges"

# legacy graph that still has "edges": must be folded into links, not duplicated
GO2="$W/legacy/graphify-out"; mkdir -p "$GO2"
cat > "$GO2/graph.json" <<'JSON'
{ "nodes": [], "edges": [ {"source":"x","target":"y","relation":"references"} ] }
JSON
cat > "$GO2/.graphify_polish_chunk_l.json" <<'JSON'
{ "nodes": [], "edges": [ {"source":"x","target":"y","relation":"references"} ] }
JSON
bash "$SCRIPT" "$W/legacy" >/dev/null 2>&1 || true
python3 - "$GO2/graph.json" <<'PY' && ok "legacy edges key folded into links" || no "legacy edges key folded into links"
import json,sys
g=json.load(open(sys.argv[1]))
assert "edges" not in g, 'legacy "edges" key survived'
assert len(g["links"])==1, f'expected 1 link after dedup, got {len(g["links"])}'
PY

rm -rf "$W"
echo "── $_pass passed, $_fail failed"
[ "$_fail" -eq 0 ]
