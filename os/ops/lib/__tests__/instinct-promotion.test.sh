#!/usr/bin/env bash
# The promotion gate must count DISTINCT PROJECTS and must ignore a model-declared
# scope. Both were live defects on 2026-09-04: 110 of 156 stored instincts were
# global while only 5 had been seen more than once, because the model's own
# "scope":"global" was taken at face value.
# Run: bash ops/lib/__tests__/instinct-promotion.test.sh
set -uo pipefail
SCRIPT="$(cd "$(dirname "$0")/../.." && pwd)/instinct-extract.sh"
_pass=0; _fail=0
ok() { echo "PASS: $1"; _pass=$((_pass+1)); }
no() { echo "FAIL: $1"; _fail=$((_fail+1)); }

H="$(mktemp -d)"; export HOME="$H"
mkdir -p "$H/.claude/instincts/traces" "$H/bin"
STORE="$H/.claude/instincts/store.jsonl"

# stub `claude`: always returns the SAME instinct, and deliberately claims global scope
cat > "$H/bin/claude" <<'SH'
#!/usr/bin/env bash
echo '[{"trigger":"t1","action":"a1","confidence":0.9,"scope":"global"}]'
SH
chmod +x "$H/bin/claude"
# the script prepends its own PATH, so PATH alone cannot shadow the real CLI
export CLAUDE_BIN="$H/bin/claude"

mk_repo() {   # $1 = name -> a git repo with a DISTINCT remote
  mkdir -p "$H/$1"
  git -C "$H/$1" init -q 2>/dev/null
  git -C "$H/$1" remote add origin "https://example.com/$1.git" 2>/dev/null
}
mk_trace() {  # $1 = repo name, $2 = session id ; 20 lines clears the 15-line floor
  : > "$H/.claude/instincts/traces/$2.trace"
  for i in $(seq 1 20); do
    printf '12:00:%02d\t%s\tBash\tcmd %s\n' "$i" "$H/$1" "$i" >> "$H/.claude/instincts/traces/$2.trace"
  done
}
row() { python3 -c "
import json,sys
rows=[json.loads(l) for l in open('$STORE') if l.strip()]
if not rows: print('NONE 0'); raise SystemExit
r=rows[0]; print(r.get('scope','?'), len(r.get('projects') or []))"; }

mk_repo one; mk_repo two

# --- 1st project ---
mk_trace one s1; CLAUDE_BIN="$H/bin/claude" bash "$SCRIPT" >/dev/null 2>&1
read -r scope nproj <<<"$(row)"
[ "$scope" = "project" ] && ok "model-declared scope:global is DISCARDED on first sight" || no "model-declared scope:global is DISCARDED (got $scope)"
[ "$nproj" = "1" ] && ok "one distinct project recorded" || no "one distinct project recorded (got $nproj)"
python3 -c "
import json;r=[json.loads(l) for l in open('$STORE') if l.strip()][0]
assert r.get('expires_at'), 'pending instinct has no TTL'" && ok "pending instinct carries a TTL" || no "pending instinct carries a TTL"

# --- SAME project again: must NOT promote ---
mk_trace one s2; CLAUDE_BIN="$H/bin/claude" bash "$SCRIPT" >/dev/null 2>&1
read -r scope nproj <<<"$(row)"
[ "$scope" = "project" ] && ok "second sighting in the SAME project does not promote" || no "second sighting in the SAME project does not promote (got $scope)"
[ "$nproj" = "1" ] && ok "distinct-project count stays 1" || no "distinct-project count stays 1 (got $nproj)"
c=$(python3 -c "
import json;r=[json.loads(l) for l in open('$STORE') if l.strip()][0];print(r['count'])")
[ "$c" = "2" ] && ok "observation count still increments" || no "observation count still increments (got $c)"

# --- a DIFFERENT project: now it promotes ---
mk_trace two s3; CLAUDE_BIN="$H/bin/claude" bash "$SCRIPT" >/dev/null 2>&1
read -r scope nproj <<<"$(row)"
[ "$scope" = "global" ] && ok "promotes at 2 distinct projects" || no "promotes at 2 distinct projects (got $scope)"
[ "$nproj" = "2" ] && ok "two distinct projects recorded" || no "two distinct projects recorded (got $nproj)"
python3 -c "
import json;r=[json.loads(l) for l in open('$STORE') if l.strip()][0]
assert 'expires_at' not in r, 'promoted instinct still carries a TTL'
assert r.get('promoted_at'), 'promotion not stamped'" && ok "promotion clears the TTL and is stamped" || no "promotion clears the TTL and is stamped"

# --- a worktree of the SAME repo must not read as a second project ---
H2="$H/one-worktree"; mkdir -p "$H2"; git -C "$H2" init -q 2>/dev/null
git -C "$H2" remote add origin "https://example.com/one.git" 2>/dev/null
python3 - <<'PY'
import hashlib, json, os
p = os.environ["HOME"] + "/.claude/instincts/store.jsonl"
# reset to EXACTLY repo "one" — projects is sorted, so [:1] kept whichever id
# sorted first, which was repo "two". That made the assertion below test nothing.
one_id = hashlib.sha1(b"https://example.com/one").hexdigest()[:12]
rows = [json.loads(l) for l in open(p) if l.strip()]
rows[0]["scope"] = "project"; rows[0]["projects"] = [one_id]
rows[0].pop("promoted_at", None)
open(p, "w").write("\n".join(json.dumps(r) for r in rows) + "\n")
PY
mk_trace one-worktree s4; CLAUDE_BIN="$H/bin/claude" bash "$SCRIPT" >/dev/null 2>&1
read -r scope nproj <<<"$(row)"
[ "$nproj" = "1" ] && ok "same remote via another path is the SAME project" || no "same remote via another path is the SAME project (got $nproj)"

# --- the store is written atomically ---
find "$H/.claude/instincts" -name 'store.jsonl.tmp.*' | grep -q . && no "no store temp files left behind" || ok "no store temp files left behind"
grep -q 'os.replace' "$SCRIPT" && ok "store write uses os.replace" || no "store write uses os.replace"

rm -rf "$H"
echo; echo "instinct-promotion: $_pass passed, $_fail failed"
[ "$_fail" -eq 0 ]
