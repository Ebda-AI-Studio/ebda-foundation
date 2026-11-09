#!/usr/bin/env bash
# graph-verify.sh — cross-check graphify's own report against an INDEPENDENT read
# of the repo.
#
# WHY: GRAPH_REPORT.md is the first thing every session is told to read, and
# nothing has ever checked whether it describes the repo as it is now. It states
# its own build commit and then says "run git rev-parse HEAD and compare" — a
# manual step, i.e. one that does not happen.
#
# THE DISCIPLINE, from agency-agents scripts/test-convert-outputs.sh:175-181:
# the expected value must come from a parser that shares NO code with the
# generator, or a generator bug moves both sides together and hides itself. So
# every expectation here comes from `git ls-files` and os.path.exists — never from
# graphify's own manifest, cache, or traversal.
#
# Checks:
#   1. FRESHNESS  built_at_commit vs HEAD, and whether tracked sources changed since.
#   2. PHANTOMS   a source_file the graph claims that does not exist on disk.  (fatal)
#   3. COVERAGE   per EXTENSION, because an aggregate percentage is misleading:
#                 graphify has no shell parser, so this repo's graph contains 0 of
#                 224 tracked .sh files while covering 109 of 123 .md. A single
#                 "33% coverage" number hides both facts. Extensions the graph
#                 handles are held to the floor; extensions it covers ZERO of are
#                 reported separately as unindexed languages — which for an OS made
#                 of bash is the finding that matters.
#
# Usage: ops/graph-verify.sh [--repo <dir>] [--coverage-floor 80]
# Exit: 0 ok · 1 phantom files or coverage below the floor · 2 no graph to verify
set -uo pipefail
REPO="."; FLOOR=80
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)            REPO="${2:?}"; shift 2 ;;
    --coverage-floor)  FLOOR="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "graph-verify: unknown argument '$1'" >&2; exit 64 ;;
  esac
done

GRAPH="$REPO/graphify-out/graph.json"
if [ ! -f "$GRAPH" ]; then
  echo "graph-verify: no graphify-out/graph.json under $REPO — nothing to verify. This is not a pass; run /graphify . first." >&2
  exit 2
fi

REPO="$REPO" GRAPH="$GRAPH" FLOOR="$FLOOR" python3 <<'PYGV'
import json, os, subprocess, sys

repo  = os.environ["REPO"]
graph = os.environ["GRAPH"]
floor = float(os.environ["FLOOR"])

with open(graph, encoding="utf-8") as fh:
    g = json.load(fh)

claimed = sorted({n["source_file"] for n in g.get("nodes", []) if n.get("source_file")})

# ---- the INDEPENDENT side: git, not graphify -------------------------------
def git(*args):
    r = subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else ""

head = git("rev-parse", "HEAD")
built = g.get("built_at_commit") or ""

EXT = {".sh", ".py", ".ts", ".tsx", ".js", ".mjs", ".md", ".json", ".yml", ".yaml", ".swift"}
tracked = [f for f in git("ls-files").split("\n")
           if f and os.path.splitext(f)[1] in EXT and not f.startswith("graphify-out/")]
tracked_set = set(tracked)

problems, notes = [], []

# 1. freshness
if not built:
    notes.append("the graph records no build commit — freshness cannot be judged")
elif head and built != head:
    behind = git("rev-list", "--count", f"{built}..{head}") or "?"
    changed = [f for f in git("diff", "--name-only", built, head).split("\n")
               if f and f in tracked_set]
    notes.append(f"STALE: built at {built[:8]}, HEAD is {head[:8]} ({behind} commits later); "
                 f"{len(changed)} indexed source file(s) changed since. Run `graphify update .`")
else:
    notes.append(f"fresh: built at HEAD ({head[:8]})")

# 2. phantoms — claimed but absent. Fatal: the report is describing files that
#    are not there, so anything it says about them is fiction.
phantom = [f for f in claimed if not os.path.exists(os.path.join(repo, f))]
if phantom:
    problems.append(f"{len(phantom)} phantom file(s) claimed by the graph but ABSENT on disk")

# 3. coverage, per extension. Which extensions the graph HANDLES is read off the
#    graph; whether it covered them is judged against git. The unindexed-language
#    finding needs no assumption at all: it is a git count next to a graph count.
by_ext_claimed, by_ext_tracked = {}, {}
for f in claimed:
    by_ext_claimed[os.path.splitext(f)[1]] = by_ext_claimed.get(os.path.splitext(f)[1], 0) + 1
for f in tracked_set:
    by_ext_tracked[os.path.splitext(f)[1]] = by_ext_tracked.get(os.path.splitext(f)[1], 0) + 1

handled = {e for e, n in by_ext_claimed.items() if n > 0}
unindexed = sorted(((e, n) for e, n in by_ext_tracked.items() if e not in handled and n >= 5),
                   key=lambda x: -x[1])

print(f"graph-verify: graph claims {len(claimed)} source file(s); git tracks "
      f"{len(tracked_set)} file(s) in indexable extensions")
for n in notes:
    print(f"  note  {n}")

low = []
for e in sorted(handled, key=lambda x: -by_ext_tracked.get(x, 0)):
    t = by_ext_tracked.get(e, 0)
    if not t:
        continue
    c = by_ext_claimed.get(e, 0)
    pct = 100.0 * min(c, t) / t
    tag = "  ok  " if pct >= floor else " LOW  "
    if pct < floor:
        low.append(f"{e} {pct:.0f}%")
    print(f"  {tag}{e or '(none)':7} {min(c,t):4}/{t:<4} {pct:5.1f}%")

for e, n in unindexed:
    print(f"  UNINDEXED  {e:7} 0/{n:<4}   the graph contains NO {e} files — "
          f"anything asked of the graph about them is answered from nothing")

for f in phantom[:20]:
    print(f"  FAIL  phantom: {f}")
if len(phantom) > 20:
    print(f"  FAIL  ...and {len(phantom)-20} more phantom file(s)")

if low:
    problems.append("below floor for: " + ", ".join(low))
if unindexed:
    problems.append(f"{len(unindexed)} unindexed extension(s): "
                    + ", ".join(f"{e} ({n} files)" for e, n in unindexed))

if problems:
    print("graph-verify: " + "; ".join(problems))
    sys.exit(1)
print("graph-verify: OK")
PYGV
