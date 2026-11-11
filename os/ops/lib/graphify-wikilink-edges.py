#!/usr/bin/env python3
"""Inject [[wikilink]] edges into a graphify graph.json.

graphify's extract_markdown() parses headings and fenced code blocks only — it has no
wikilink parser. Every cross-file [[link]] in a memory vault is therefore invisible to
the structural extractor, and cross-file edges only ever appear when the lossy LLM
semantic pass happens to notice them. On the global memory graph that left 1,350
explicit links represented by 306 `references` edges and 72% of nodes isolated.

This pass reads the links straight from the markdown (ground truth, zero LLM) and adds:
  - `references` file -> file edges, one per resolved [[link]]  (EXTRACTED, 1.0)
  - `contains`   file -> semantic-node edges, so the link backbone actually joins the
                 existing clusters instead of floating above them

Idempotent: re-running adds nothing new. Safe to wire into update-memory-pipeline.sh.

Link resolution is deliberately forgiving, because the vault's own convention is loose:
notes are written as [[scaling-cliff]] but filed as feedback-scaling-cliff.md, and global
memory links to notes that live in the vault. Resolution order per link is exact stem ->
existing node id -> known type prefix (unique match only) -> sibling corpus. Anything still
unresolved is reported, never silently dropped: per global CLAUDE.md a dangling [[link]]
marks a note worth writing.

Usage: graphify-wikilink-edges.py [dir] [--also <dir>]...
       dir defaults to cwd and must contain graphify-out/graph.json
       --also adds a sibling corpus for resolution only (its graph is not touched)
"""
from __future__ import annotations

import json
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

# _graphify-nodes is graphify's own Obsidian export — derived output, not source. Scanning
# it makes every real note look like an ambiguous duplicate of its own generated copy,
# which silently unresolves the most-linked notes in the vault.
SKIP_DIRS = {"graphify-out", "_graphify-nodes", "_claude-memory", "node_modules",
             ".git", ".obsidian", "_retired"}
WIKILINK = re.compile(r"\[\[([^\]|#]+)(?:[#|][^\]]*)?\]\]")
FENCE = re.compile(r"^\s*```")
# Inline code spans are quotation, not linkage. Cloudflare Pages' catch-all handler is
# literally named `functions/ar/[[path]].js` and a proposal template documents its
# `[[CLIENT_AR]]` fields — both are filenames being QUOTED, and counting them as links
# reported 12 permanently-broken links that no note could ever satisfy. Worse, the only
# way to "fix" them in the note is to corrupt the filename being documented. Strip code
# spans before matching (2026-09-09).
CODE_SPAN = re.compile(r"(`+)(?:.|\n)*?\1")
# Memory notes are filed with a type prefix but linked without it — [[scaling-cliff]]
# for feedback-scaling-cliff.md. Two thirds of dangling links are just this.
TYPE_PREFIXES = ("feedback_", "reference_", "project_", "content_", "user_", "deployment_")


def norm(s: str) -> str:
    """Match graphify's _make_id() normalization. Some links are written with the file
    extension ([[reference-iceberg-audit.md]]); the target is the same note."""
    s = s.strip()
    if s.lower().endswith(".md"):
        s = s[:-3]
    return re.sub(r"[^a-zA-Z0-9]+", "_", s).strip("_").lower()


def md_files(root: Path) -> list[Path]:
    out = []
    for p in root.rglob("*.md"):
        if any(part in SKIP_DIRS for part in p.parts):
            continue
        out.append(p)
    return out


def links_in(path: Path) -> list[str]:
    """Wikilink targets in a file, skipping fenced code blocks."""
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except Exception:
        return []
    targets, in_fence = [], False
    for line in text.splitlines():
        if FENCE.match(line):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        targets.extend(m.group(1).strip()
                       for m in WIKILINK.finditer(CODE_SPAN.sub(" ", line)))
    return targets


def main() -> int:
    argv = sys.argv[1:]
    extra_roots: list[Path] = []
    positional: list[str] = []
    i = 0
    while i < len(argv):
        if argv[i] == "--also" and i + 1 < len(argv):
            extra_roots.append(Path(argv[i + 1]).resolve())
            i += 2
        else:
            positional.append(argv[i])
            i += 1

    root = Path(positional[0] if positional else ".").resolve()
    gpath = root / "graphify-out" / "graph.json"
    if not gpath.exists():
        print(f"FAIL: {gpath} not found")
        return 1

    graph = json.loads(gpath.read_text())
    nodes: list[dict] = graph["nodes"]
    links: list[dict] = graph.setdefault("links", graph.pop("edges", []))

    by_id = {n["id"]: n for n in nodes}
    # semantic nodes grouped by the file they came from
    by_source: dict[str, list[dict]] = defaultdict(list)
    for n in nodes:
        sf = n.get("source_file")
        if sf:
            by_source[str(Path(sf).resolve()) if Path(sf).is_absolute() else sf].append(n)

    files = md_files(root)
    # Sibling corpora are resolution targets only — we never scan them for outbound links
    # or rewrite their graphs, we just let this graph point at notes that live there.
    extra_files = [p for d in extra_roots if d != root for p in md_files(d)]

    # stem -> path, flagging ambiguous stems so we can qualify them with the parent dir.
    # Built from THIS corpus only: a sibling holding the same stem is a fallback target,
    # not a collision, and treating it as one unresolves the note against itself.
    stem_paths: dict[str, list[Path]] = defaultdict(list)
    for p in files:
        stem_paths[norm(p.stem)].append(p)

    def node_id_for(path: Path) -> str:
        """The node id representing this file. Reuse the semantic node when its id is the
        normalized stem; qualify with the parent dir when two files share a stem."""
        base = norm(path.stem)
        if len(stem_paths.get(base, [])) > 1:
            return norm(f"{path.parent.name}_{path.stem}")
        return base

    added_nodes = 0
    created: dict[str, Path] = {}

    def ensure_node(path: Path) -> str:
        nonlocal added_nodes
        nid = node_id_for(path)
        if nid in by_id:
            return nid
        title = path.stem.replace("-", " ").replace("_", " ").title()
        node = {
            "id": nid,
            "label": title,
            "file_type": "document",
            "source_file": str(path),
            "source_location": "L1",
            # Anchor only — carries a filename, not extracted knowledge. Tagged so the
            # coverage metric in graphify-backfill.sh does not count a file as "graphed"
            # just because this pass gave it a node to hang its wikilinks on.
            "origin": "wikilink-pass",
        }
        nodes.append(node)
        by_id[nid] = node
        created[nid] = path
        added_nodes += 1
        return nid

    existing = {(e["source"], e["target"], e.get("relation")) for e in links}
    resolvable = {norm(p.stem): p for p in files}
    for stem, paths in stem_paths.items():
        if len(paths) > 1:
            resolvable.pop(stem, None)  # ambiguous within this corpus
    # Siblings fill gaps only — never shadow or unresolve a note this corpus owns.
    for p in extra_files:
        resolvable.setdefault(norm(p.stem), p)

    # Prefix-tolerant index: feedback-scaling-cliff.md is also reachable as [[scaling-cliff]].
    # Only when the bare suffix maps to exactly one real note — [[x]] matching both
    # feedback-x and reference-x is a genuine ambiguity and stays unresolved.
    by_suffix: dict[str, set[str]] = defaultdict(set)
    for stem in resolvable:
        for pre in TYPE_PREFIXES:
            if stem.startswith(pre) and len(stem) > len(pre):
                by_suffix[stem[len(pre):]].add(stem)
    ambiguous: Counter[str] = Counter()

    def resolve(key: str) -> Path | None:
        hit = resolvable.get(key)
        if hit is not None:
            return hit
        cands = by_suffix.get(key)
        if cands and len(cands) == 1:
            return resolvable[next(iter(cands))]
        if cands:
            ambiguous[key] += 1
        return None

    added_refs = 0
    unresolved: Counter[str] = Counter()
    touched: set[str] = set()

    for path in files:
        targets = links_in(path)
        if not targets:
            continue
        if not any(resolve(norm(t)) is not None or norm(t) in by_id for t in targets):
            # still record unresolved so the report is honest
            for t in targets:
                unresolved[t] += 1
            continue
        sid = ensure_node(path)
        touched.add(sid)
        for t in targets:
            key = norm(t)
            tgt_path = resolve(key)
            if tgt_path is not None:
                tid = ensure_node(tgt_path)
            elif key in by_id:
                tid = key
            else:
                unresolved[t] += 1
                continue
            if tid == sid:
                continue
            touched.add(tid)
            if (sid, tid, "references") in existing:
                continue
            links.append({
                "source": sid,
                "target": tid,
                "relation": "references",
                "confidence": "EXTRACTED",
                "confidence_score": 1.0,
                "source_file": str(path),
                "weight": 1.0,
            })
            existing.add((sid, tid, "references"))
            added_refs += 1

    # Join the wikilink backbone to the existing semantic clusters. Rebuild the
    # source_file index first — nodes created above are not in the original one, and
    # without this the pass needs a second run to settle.
    by_source = defaultdict(list)
    for n in nodes:
        sf = n.get("source_file")
        if sf:
            by_source[sf].append(n)

    added_contains = 0
    for nid in sorted(touched):
        node = by_id[nid]
        sf = node.get("source_file")
        if not sf:
            continue
        for sem in by_source.get(sf, []):
            if sem["id"] == nid:
                continue
            if (nid, sem["id"], "contains") in existing:
                continue
            links.append({
                "source": nid,
                "target": sem["id"],
                "relation": "contains",
                "confidence": "EXTRACTED",
                "confidence_score": 1.0,
                "source_file": sf,
                "weight": 1.0,
            })
            existing.add((nid, sem["id"], "contains"))
            added_contains += 1

    # New nodes inherit a community so the report/cluster view still accounts for them:
    # the modal community of the file's own semantic nodes, else of its link neighbours.
    if created:
        neighbours: dict[str, list[str]] = defaultdict(list)
        for e in links:
            neighbours[e["source"]].append(e["target"])
            neighbours[e["target"]].append(e["source"])
        for nid, path in created.items():
            node = by_id[nid]
            votes = Counter()
            for sem in by_source.get(str(path), []):
                if sem.get("community") is not None:
                    votes[sem["community"]] += 1
            if not votes:
                for other in neighbours.get(nid, []):
                    c = by_id.get(other, {}).get("community")
                    if c is not None:
                        votes[c] += 1
            if votes:
                node["community"] = votes.most_common(1)[0][0]

    graph["links"] = links
    gpath.write_text(json.dumps(graph, indent=2))

    total_links = sum(len(links_in(p)) for p in files)
    print(f"  wikilinks: {total_links} found in {len(files)} md files")
    print(f"  +{added_refs} references edges, +{added_contains} contains edges, "
          f"+{added_nodes} file nodes")
    if ambiguous:
        top = ", ".join(f"{k}({v})" for k, v in ambiguous.most_common(3))
        print(f"  {sum(ambiguous.values())} links ambiguous across type prefixes "
              f"(e.g. feedback-X and reference-X both exist) — top: {top}")
    if unresolved:
        top = ", ".join(f"{k}({v})" for k, v in unresolved.most_common(5))
        print(f"  {sum(unresolved.values())} unresolved links to {len(unresolved)} "
              f"notes that do not exist — top: {top}")
    print(f"  graph now: {len(nodes)} nodes / {len(links)} edges")
    return 0


if __name__ == "__main__":
    sys.exit(main())
