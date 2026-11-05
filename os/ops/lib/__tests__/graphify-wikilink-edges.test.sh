#!/usr/bin/env bash
# graphify-wikilink-edges.test.sh — the scanner must read links, not quotations.
#
# A [[link]] inside an inline code span is a filename being documented, not a link:
# Cloudflare Pages' catch-all really is named `functions/ar/[[path]].js`. Counting it
# reported permanently-unresolvable links whose only "fix" was to corrupt the filename.
# Fails against the pre-2026-09-09 scanner, which stripped fenced blocks only.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../graphify-wikilink-edges.py"
[ -f "$LIB" ] || { echo "FAIL: $LIB not found"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/graphify-out"
cat > "$TMP/graphify-out/graph.json" <<'JSON'
{"nodes": [], "links": []}
JSON
cat > "$TMP/real-note.md" <<'MD'
# Real note
A genuine link to [[other-note]] in prose.
An inline code span naming a file: `functions/ar/[[path]].js` owns the /ar tree.
Template fields: `[[CLIENT_AR]]` `[[DATE]]`.

```
fenced [[never-counted]]
```
MD
cat > "$TMP/other-note.md" <<'MD'
# Other note
MD

out="$(cd "$TMP" && python3 "$LIB" . 2>&1)"
fails=0

# The prose link resolves and becomes an edge.
echo "$out" | grep -q "+1 references edges" || { echo "FAIL: real [[other-note]] link not turned into an edge"; echo "$out"; fails=1; }

# The quoted ones must not be reported as unresolved at all.
if echo "$out" | grep -q "unresolved"; then
  echo "FAIL: inline-code [[path]] / [[CLIENT_AR]] / [[DATE]] counted as unresolved links"
  echo "$out"
  fails=1
fi

[ "$fails" -eq 0 ] && echo "PASS: graphify-wikilink-edges ignores inline code spans, keeps prose links"
exit "$fails"
