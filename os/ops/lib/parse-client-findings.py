#!/usr/bin/env python3
"""Turn hand-written client audit findings into candidate lens CLASSES.

Reads report paths on stdin (one per line), prints `class<TAB>title`.

A finding a human wrote up is a defect class the pack should catch by itself
next time. The class is derived from the finding's TITLE, with this client's
wording stripped down to the shape of the defect -- `SEC-004: Company portal has
no authentication at all` becomes `company-portal-authentication`, so the same
defect in another repo matches the same class and is not proposed twice.
"""
import pathlib
import re
import sys

STOP = {
    "the", "a", "an", "is", "are", "no", "has", "have", "not", "at", "all",
    "in", "on", "of", "to", "and", "with", "by", "it", "its", "any", "for",
}

seen: dict[str, str] = {}
for line in sys.stdin.read().splitlines():
    p = pathlib.Path(line.strip())
    if not line.strip() or not p.is_file():
        continue
    try:
        txt = p.read_text(encoding="utf8", errors="replace")
    except OSError:
        continue
    for _ident, title in re.findall(r"^#{2,4}\s*([A-Z]{2,5}-\d{1,3}):\s*(.+)$", txt, re.M):
        t = title.strip().rstrip(".")
        words = [w for w in re.findall(r"[a-z]+", t.lower()) if w not in STOP]
        if len(words) < 2:
            continue
        seen.setdefault("-".join(words[:4]), t[:110])

for cls, title in seen.items():
    print(f"{cls}\t{title}")
