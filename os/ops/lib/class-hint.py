#!/usr/bin/env python3
"""Which existing lenses LOOK related to a prose-derived finding class?

Prints up to three lens ids, most similar first, or nothing.

This is a HINT, never a verdict. Three attempts at using word overlap to decide
"already covered" all mis-attributed on the real fleet -- `unrestricted-file-
upload` matched `cicd` (which says "upload artifact"), `sql-injection-raw-query`
matched nothing while `php-sqli` existed, and `plaintext-password-storage`
matched `data-ui-coverage`. A wrong suppression is the expensive direction: it
hides a real gap AND tells the reader the wrong lens owns it.

So the cycle proposes the candidate either way and attaches this list for the
human who reads the issue. Exact id matching (`_covered_by` in
audit-pack-daily.sh) still suppresses properly for the watchdog, whose classes
are already id-shaped.

Usage: class-hint.py <fleet-dir> <class-slug>
"""
import pathlib
import re
import sys

STOP = {
    "the", "and", "with", "from", "that", "this", "your", "into", "over",
    "have", "has", "not", "all", "any", "for", "its", "was", "are",
}
COMMON_SHARE = 0.25

fleet = pathlib.Path(sys.argv[1])
words = [w for w in sys.argv[2].split("-") if len(w) >= 4 and w not in STOP]
lens_dir = fleet / "lenses"
if not words or not lens_dir.is_dir():
    sys.exit(0)


def stem(w: str) -> str:
    return w[:-1] if len(w) > 5 and w.endswith("s") else w


corpus: dict[str, str] = {}
for manifest in sorted(lens_dir.glob("*.json")):
    lens = manifest.stem
    text = manifest.read_text(encoding="utf8", errors="replace").lower()
    rubric = fleet / "rubric" / f"{lens}.md"
    if rubric.is_file():
        text += rubric.read_text(encoding="utf8", errors="replace").lower()
    corpus[lens] = text

total = len(corpus) or 1
# A word in most lenses is not evidence of anything.
weighted = [
    stem(w) for w in words
    if 0 < sum(1 for t in corpus.values() if stem(w) in t) / total <= COMMON_SHARE
]
if not weighted:
    sys.exit(0)

scored = sorted(
    ((sum(1 for w in weighted if w in t), lens) for lens, t in corpus.items()),
    reverse=True,
)
print(" ".join(lens for hits, lens in scored[:3] if hits > 0))
