#!/usr/bin/env python3
"""Pull advisory ids out of an advisory feed. Prints `id<TAB>summary`, capped.

Handles BOTH shapes, because the obvious one does not work: GitHub's
`advisories.atom` answers 406 (measured 2026-09-23, with and without a
User-Agent), so the real source is the JSON REST API at
`api.github.com/advisories?ecosystem=…`. Atom is kept for project-specific
feeds that do serve it.

Kept as a file rather than an inline heredoc because the caller already nests
heredocs two deep and a third is a parse error waiting to happen.
"""
import json
import re
import sys

cap = int(sys.argv[1]) if len(sys.argv) > 1 else 25
raw = sys.stdin.read()

rows: list[tuple[str, str]] = []

try:
    doc = json.loads(raw)
except ValueError:
    doc = None

if isinstance(doc, list):
    for a in doc:
        if not isinstance(a, dict):
            continue
        ident = a.get("ghsa_id") or a.get("cve_id")
        if ident:
            rows.append((ident, (a.get("summary") or "").strip()))
else:
    ids = re.findall(r"(GHSA-[0-9a-z]{4}-[0-9a-z]{4}-[0-9a-z]{4}|CVE-\d{4}-\d{4,7})", raw)
    # The first <title> of an atom feed names the feed, not an entry.
    titles = [t.strip() for t in re.findall(r"<title[^>]*>([^<]{4,160})</title>", raw)][1:]
    for n, ident in enumerate(dict.fromkeys(ids)):
        rows.append((ident, titles[n] if n < len(titles) else ""))

seen = set()
printed = 0
for ident, title in rows:
    if ident in seen:
        continue
    seen.add(ident)
    print(f"{ident}\t{title}")
    printed += 1
    if printed >= cap:
        break
