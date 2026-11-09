#!/usr/bin/env bash
# graphify-merge-chunks.sh — fold Sonnet-written polish chunks into a graph.json.
#
# The memory pipeline's EXTRACT=skip path REGENERATES the report but never actually
# merged the .graphify_polish_chunk_*.json files — so Sonnet-extracted nodes piled up
# unmerged and coverage stayed stuck. This does the merge the pipeline was missing:
# reads every polish chunk in <dir>/graphify-out/, appends its nodes (dedup by id) +
# edges (dedup by source|target|relation) into graph.json, and archives merged chunks so
# they aren't re-counted. Idempotent — re-running merges nothing new.
#
# 2026-09-02 — the NODE merge above was fixed in July 2026; the EDGE merge in the same
# function stayed a silent no-op until now, for two reasons: (1) edges were keyed on
# e["type"] but graphify edges carry "relation", so the key's third element was None for
# every edge and the `None in k` guard rejected 100% of them; (2) the graph was read and
# written at g["edges"] while NetworkX node-link format keeps the edge list at g["links"],
# so whatever survived went to a key nothing reads. Every Sonnet-extracted relationship
# since this script was written was dropped. Locked down by
# lib/__tests__/graphify-merge-chunks.test.sh, which fails against the pre-fix script.
#
#   graphify-merge-chunks.sh <corpus_dir>        merge chunks in <dir>/graphify-out/
#   graphify-merge-chunks.sh <corpus_dir> --keep don't archive chunks after merge
set -uo pipefail
DIR="${1:-.}"; KEEP="${2:-}"
GO="$DIR/graphify-out"
G="$GO/graph.json"
[ -f "$G" ] || { echo "no graph.json at $G"; exit 1; }

python3 - "$GO" "$G" "$KEEP" <<'PY'
import json, sys, glob, os, time
go, gpath, keep = sys.argv[1], sys.argv[2], sys.argv[3]

g = json.load(open(gpath))
nodes = g.get("nodes", [])
# graph.json is NetworkX node-link format: the edge list lives under "links",
# NOT "edges". Reading g["edges"] always returned [] and writing it back created
# a key nothing else reads, so merged edges vanished. Fold a legacy/stray "edges"
# key in — the same migration ops/lib/graphify-wikilink-edges.py performs.
edges = g.setdefault("links", g.pop("edges", []))
have_n = {n.get("id") for n in nodes if n.get("id")}
# Edges carry "relation" (graphify) — "type" is only accepted for older chunks.
# Keying on "type" alone made the third element None for EVERY edge, and the
# `None in k` guard below then skipped 100% of them: the bug that made this
# whole function a silent no-op for edges while nodes merged fine.
def ekey(e): return (e.get("source"), e.get("target"), e.get("relation") or e.get("type"))
have_e = {ekey(e) for e in edges}

n0, e0 = len(nodes), len(edges)
chunks = sorted(glob.glob(os.path.join(go, ".graphify_polish_chunk_*.json")))
added_n = added_e = dropped = dropped_e = merged_files = 0
archive = os.path.join(go, "merged-chunks")

for c in chunks:
    try:
        d = json.load(open(c))
    except Exception as ex:
        # QUARANTINE, never just skip. A chunk is LLM-written (claude -p), so
        # malformed JSON is a normal, expected outcome — one unescaped newline
        # inside a string is enough. Skipping alone left the file in the glob
        # forever, so a single bad extraction printed the same warning on
        # EVERY subsequent pipeline run. A permanent warning is worse than a
        # loud one-off: it trains the reader to ignore this line, and the next
        # genuinely-new bad chunk hides in the noise. Moving it out of the
        # glob makes the failure report exactly once, while keeping the file
        # for diagnosis instead of destroying evidence.
        rej = os.path.join(go, "rejected-chunks")
        os.makedirs(rej, exist_ok=True)
        dest = os.path.join(rej, os.path.basename(c))
        try:
            os.replace(c, dest)
            print(f"  QUARANTINED (bad json): {os.path.basename(c)} -> rejected-chunks/ ({ex})")
        except OSError as mv:
            # Never let cleanup failure abort the merge of the GOOD chunks.
            print(f"  skip (bad json, quarantine failed): {os.path.basename(c)} ({ex}; {mv})")
        continue
    cn = ce = 0
    for n in d.get("nodes", []):
        nid = n.get("id"); src = n.get("source_file") or (n.get("properties") or {}).get("source_file")
        if not nid or not src:            # graphify drops nodes without source_file
            dropped += 1; continue
        if nid in have_n:                 # dedup
            continue
        have_n.add(nid); nodes.append(n); added_n += 1; cn += 1
    for e in d.get("edges", []) + d.get("links", []):
        # Require only the endpoints. A missing relation is not a malformed edge,
        # and rejecting the whole triple on any None was what dropped everything.
        if not e.get("source") or not e.get("target"):
            dropped_e += 1; continue
        k = ekey(e)
        if k in have_e: continue
        have_e.add(k); edges.append(e); added_e += 1; ce += 1
    merged_files += 1
    if not keep:
        os.makedirs(archive, exist_ok=True)
        os.rename(c, os.path.join(archive, os.path.basename(c)))
    print(f"  merged {os.path.basename(c)}: +{cn} nodes, +{ce} edges")

g["nodes"], g["links"] = nodes, edges
json.dump(g, open(gpath, "w"), indent=2)
print(f"── {merged_files} chunks | nodes {n0}->{len(nodes)} (+{added_n}) | edges {e0}->{len(edges)} (+{added_e}) | dropped(no source_file) {dropped} | dropped(no endpoints) {dropped_e}")
PY
