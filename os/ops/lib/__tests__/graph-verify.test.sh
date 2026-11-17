#!/usr/bin/env bash
# graph-verify.sh must catch a graph that claims a file which is not there, and a
# graph built at a commit that is no longer HEAD. Both are asserted by BUILDING a
# fixture repo and a hand-written graph.json — the expectation never comes from
# graphify, which is the whole point of the check.
# Run: bash ops/lib/__tests__/graph-verify.test.sh
set -uo pipefail
SCRIPT="$(cd "$(dirname "$0")/../.." && pwd)/graph-verify.sh"
_pass=0; _fail=0
ok() { echo "PASS: $1"; _pass=$((_pass+1)); }
no() { echo "FAIL: $1"; _fail=$((_fail+1)); }
saw() { grep -q "$1" <<<"$2"; }

mkrepo() {                       # $1 = dir
  mkdir -p "$1/src" "$1/graphify-out"
  for f in a b c; do printf 'def %s():\n    return 1\n' "$f" > "$1/src/$f.py"; done
  git -C "$1" init -q
  git -C "$1" -c user.email=t@t -c user.name=t add -A >/dev/null
  git -C "$1" -c user.email=t@t -c user.name=t commit -qm init
}
writegraph() {                   # $1 = dir, $2 = json array of source_files, $3 = commit
  python3 -c "
import json,sys
d={'nodes':[{'id':f.replace('/','_'),'source_file':f} for f in json.loads(sys.argv[2])],
   'links':[], 'built_at_commit': sys.argv[3]}
json.dump(d, open(sys.argv[1]+'/graphify-out/graph.json','w'))" "$1" "$2" "$3"
}

# --- clean: all three files claimed, built at HEAD ---
R="$(mktemp -d)"; mkrepo "$R"; H="$(git -C "$R" rev-parse HEAD)"
writegraph "$R" '["src/a.py","src/b.py","src/c.py"]' "$H"
out="$(bash "$SCRIPT" --repo "$R" 2>&1 || true)"
bash "$SCRIPT" --repo "$R" >/dev/null 2>&1 && ok "a complete, fresh graph passes" || no "a complete, fresh graph passes"
saw "fresh: built at HEAD" "$out" && ok "reports freshness" || no "reports freshness"
rm -rf "$R"

# --- phantom: claims a file that does not exist ---
R="$(mktemp -d)"; mkrepo "$R"; H="$(git -C "$R" rev-parse HEAD)"
writegraph "$R" '["src/a.py","src/b.py","src/c.py","src/ghost.py"]' "$H"
out="$(bash "$SCRIPT" --repo "$R" 2>&1 || true)"
saw "phantom: src/ghost.py" "$out" && ok "names the phantom file" || no "names the phantom file"
bash "$SCRIPT" --repo "$R" >/dev/null 2>&1 && no "a phantom file fails the run" || ok "a phantom file fails the run"
rm -rf "$R"

# --- stale: built at an older commit ---
R="$(mktemp -d)"; mkrepo "$R"; OLD="$(git -C "$R" rev-parse HEAD)"
echo "x = 2" >> "$R/src/a.py"
git -C "$R" -c user.email=t@t -c user.name=t commit -aqm second
writegraph "$R" '["src/a.py","src/b.py","src/c.py"]' "$OLD"
out="$(bash "$SCRIPT" --repo "$R" 2>&1 || true)"
saw "STALE" "$out" && ok "detects a stale build commit" || no "detects a stale build commit"
saw "1 indexed source file" "$out" && ok "counts the changed indexed files" || no "counts the changed indexed files"
rm -rf "$R"

# --- unindexed language: shell tracked, none in the graph ---
R="$(mktemp -d)"; mkrepo "$R"
for i in $(seq 1 6); do printf '#!/bin/bash\necho %s\n' "$i" > "$R/src/s$i.sh"; done
git -C "$R" -c user.email=t@t -c user.name=t add -A >/dev/null
git -C "$R" -c user.email=t@t -c user.name=t commit -qm shell
H="$(git -C "$R" rev-parse HEAD)"
writegraph "$R" '["src/a.py","src/b.py","src/c.py"]' "$H"
out="$(bash "$SCRIPT" --repo "$R" 2>&1 || true)"
saw "UNINDEXED  .sh" "$out" && ok "reports an unindexed language" || no "reports an unindexed language"
bash "$SCRIPT" --repo "$R" >/dev/null 2>&1 && no "an unindexed language fails the run" || ok "an unindexed language fails the run"
rm -rf "$R"

# --- no graph at all is exit 2, NOT a pass ---
R="$(mktemp -d)"; mkrepo "$R"
bash "$SCRIPT" --repo "$R" >/dev/null 2>&1; rc=$?
[ "$rc" = "2" ] && ok "a repo with no graph exits 2" || no "a repo with no graph exits 2 (got $rc)"
rm -rf "$R"

echo; echo "graph-verify: $_pass passed, $_fail failed"
[ "$_fail" -eq 0 ]
