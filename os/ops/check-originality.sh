#!/usr/bin/env bash
# check-originality.sh — find near-duplicate markdown in a corpus.
#
# WHY: the memory system's rule is one rolled-up file per THEME, and nothing has
# ever enforced it. A near-duplicate lesson is worse than a missing one: it splits
# the signal so neither copy gets read, and the index grows without the knowledge
# growing. Same problem for audit lens packs and standard/ docs.
#
# Ported from agency-agents scripts/check-agent-originality.sh (MIT). The part
# worth taking is ENTITY NEUTRALISATION: swapping the repo/client/product name and
# little else is exactly how a duplicate gets written, so those nouns are blanked
# before shingling and a re-skin still scores as a duplicate.
#
# Usage:
#   ops/check-originality.sh --dir <path> [--fail-at 40] [--warn-at 20] [--top 15]
#                            [--exclude <glob>]...   repeatable, matched on the
#                            path relative to --dir
#
# Calibration, measured 2026-09-04 over the 1,099-file memory root: excluding the
# generated `_scoped/` mirror, 27,000+ overlapping pairs have a median overlap of
# 0.07% and the worst genuine pair is ~51%. The `_scoped/` mirror duplicates the
# canonical files by design and produces exact 100% pairs, so it must be excluded
# when auditing the root — otherwise the real signal sits under three mirrors.
# Exit: 0 clean · 1 a pair at/above --fail-at · 2 nothing was compared
set -uo pipefail

DIR=""; FAIL_AT=40; WARN_AT=20; TOP=15; EXCLUDES=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dir)     DIR="${2:?--dir needs a path}"; shift 2 ;;
    --fail-at) FAIL_AT="${2:?}"; shift 2 ;;
    --warn-at) WARN_AT="${2:?}"; shift 2 ;;
    --top)     TOP="${2:?}"; shift 2 ;;
    --exclude) EXCLUDES="${EXCLUDES}${EXCLUDES:+:}${2:?--exclude needs a glob}"; shift 2 ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "check-originality: unknown argument '$1'" >&2; exit 64 ;;
  esac
done
[ -n "$DIR" ] || { echo "check-originality: --dir is required" >&2; exit 64; }
[ -d "$DIR" ] || { echo "check-originality: no such directory: $DIR" >&2; exit 64; }

DIR="$DIR" FAIL_AT="$FAIL_AT" WARN_AT="$WARN_AT" TOP="$TOP" EXCLUDES="$EXCLUDES" python3 <<'PYORIG'
import os, re, sys, glob, itertools

d        = os.environ["DIR"]
fail_at  = float(os.environ["FAIL_AT"])
warn_at  = float(os.environ["WARN_AT"])
top      = int(os.environ["TOP"])
excludes = [e for e in (os.environ.get("EXCLUDES") or "").split(":") if e]

# Proper nouns neutralised so a find-and-replace re-skin (swap the repo/client and
# little else) still scores as a near-duplicate. Extend as new names appear.
ENTITY = re.compile(
    r'\b(fwb|wbs|force[\-_ ]?ai|forceai|force[\-_ ]?media|whisky|umbra|neon|cloudflare|'
    r'railway|vercel|supabase|prisma|inngest|myfatoorah|gcc[\-_ ]?horse[\-_ ]?market|'
    r'horse[\-_ ]?market|mypovonai|legende|salam|elsalam|om[\-_ ]?hassan|da[\-_ ]?gusto|'
    r'pecannbee|wady[\-_ ]?aljuz|quote[\-_ ]?studio|digital[\-_ ]?card|kuwait|egypt|'
    r'arabic|english)\b', re.I)

def strip_frontmatter(t):
    if t.startswith("---"):
        parts = t.split("---", 2)
        if len(parts) >= 3:
            return parts[2]
    return t

def tokens(text):
    text = ENTITY.sub(" ", strip_frontmatter(text).lower())
    text = re.sub(r"[^a-z0-9 ]", " ", text)
    return text.split()

def shingles(words, k=8):
    return set(" ".join(words[i:i + k]) for i in range(max(0, len(words) - k + 1)))

def jaccard(a, b):
    return len(a & b) / len(a | b) if a and b else 0.0

import fnmatch
files = sorted(glob.glob(os.path.join(d, "**", "*.md"), recursive=True))
skipped = 0
def excluded(p):
    r = os.path.relpath(p, d)
    return any(fnmatch.fnmatch(r, g) for g in excludes)
corpus = {}
for f in files:
    if excluded(f):
        skipped += 1
        continue
    try:
        sh = shingles(tokens(open(f, encoding="utf-8", errors="replace").read()))
    except OSError:
        continue
    if sh:                      # a file too short to shingle cannot be compared
        corpus[f] = sh

# An empty corpus is a FINDING, not a pass: a run that compared nothing must not
# report "no duplicates". This is the same fail-open shape as a gate over no input.
if len(corpus) < 2:
    print(f"check-originality: only {len(corpus)} comparable file(s) under {d} — "
          "NOTHING was compared. This is not a clean result.", file=sys.stderr)
    sys.exit(2)

pairs = []
for a, b in itertools.combinations(sorted(corpus), 2):
    s = jaccard(corpus[a], corpus[b]) * 100
    if s > 0.0:
        pairs.append((s, a, b))
pairs.sort(reverse=True)

def rel(p): return os.path.relpath(p, d)

print(f"check-originality: {len(corpus)} files ({skipped} excluded), {len(pairs)} "
      f"overlapping pair(s) (fail>={fail_at}%, warn>={warn_at}%)")
if pairs:
    print(f"  worst pair: {pairs[0][0]:.2f}%   median overlap of overlapping pairs: "
          f"{pairs[len(pairs)//2][0]:.2f}%")
for s, a, b in pairs[:top]:
    mark = "FAIL" if s >= fail_at else ("warn" if s >= warn_at else "    ")
    print(f"  {mark} {s:6.2f}%  {rel(a)}  <->  {rel(b)}")

failed = [p for p in pairs if p[0] >= fail_at]
if failed:
    print(f"\ncheck-originality: {len(failed)} pair(s) at/above {fail_at}% — "
          "merge them into one file per theme.")
    sys.exit(1)
print("check-originality: no pair at or above the fail threshold.")
PYORIG
