#!/usr/bin/env bash
# Test scan-lockfile.sh — picks the lockfile a scanner should actually read.
# Run: bash ops/lib/__tests__/scan-lockfile.test.sh
set -uo pipefail

LIB="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$LIB/scan-lockfile.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

_pass=0
_fail=0
check() {
  local label="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then echo "PASS: $label"; _pass=$((_pass+1))
  else echo "FAIL: $label — got [$got] want [$want]"; _fail=$((_fail+1)); fi
}

git config --global init.defaultBranch main >/dev/null 2>&1 || true

# --- build an "origin" with a PATCHED lockfile, and a clone left BEHIND ---------
# This reproduces mypovonai on 2026-08-18: origin had the security fix (PR #2,
# 3 weeks earlier) but the local checkout was 2 commits behind, so the scanner
# read a lockfile still naming the vulnerable versions and reported CVEs that
# had already been fixed.
ORIGIN="$TMP/origin"
mkdir -p "$ORIGIN" && cd "$ORIGIN"
git init -q --bare 2>/dev/null

WORK="$TMP/work"
git clone -q "$ORIGIN" "$WORK" 2>/dev/null
cd "$WORK"
git config user.email t@t.t; git config user.name t
printf '{"name":"x","packages":{"node_modules/left-pad":{"version":"1.0.0"}}}\n' > package-lock.json
git add package-lock.json && git commit -qm "vulnerable"
git push -q origin HEAD:main 2>/dev/null
git branch -q -M main 2>/dev/null

# clone the CONSUMER checkout at the vulnerable commit, then advance origin
CONSUMER="$TMP/consumer"
git clone -q "$ORIGIN" "$CONSUMER" 2>/dev/null

cd "$WORK"
printf '{"name":"x","packages":{"node_modules/left-pad":{"version":"9.9.9"}}}\n' > package-lock.json
git commit -qam "patched"
git push -q origin HEAD:main 2>/dev/null

# --- the consumer checkout is now stale -----------------------------------------
OUT="$TMP/out.json"
STATUS=$(bash "$SCRIPT" "$CONSUMER" "$OUT" 2>/dev/null)
ver=$(python3 -c "import json;print(json.load(open('$OUT'))['packages']['node_modules/left-pad']['version'])" 2>/dev/null)

check "stale checkout is scanned at ORIGIN, not the stale worktree" "$ver" "9.9.9"
check "status reports it was behind" "$(printf '%s' "$STATUS" | grep -o 'behind=[0-9]*')" "behind=1"
check "status names the ref actually scanned" "$(printf '%s' "$STATUS" | grep -o 'ref=origin/main')" "ref=origin/main"

# --- an UP-TO-DATE checkout must report behind=0 ---------------------------------
cd "$CONSUMER" && git fetch -q origin 2>/dev/null && git merge -q --ff-only origin/main 2>/dev/null
STATUS2=$(bash "$SCRIPT" "$CONSUMER" "$OUT" 2>/dev/null)
check "fresh checkout reports behind=0" "$(printf '%s' "$STATUS2" | grep -o 'behind=[0-9]*')" "behind=0"
ver2=$(python3 -c "import json;print(json.load(open('$OUT'))['packages']['node_modules/left-pad']['version'])" 2>/dev/null)
check "fresh checkout still yields the patched lockfile" "$ver2" "9.9.9"

# --- UNCOMMITTED local edits must not be scanned as if deployed -------------------
# A dirty working copy is not what is running in production.
cd "$CONSUMER"
printf '{"name":"x","packages":{"node_modules/left-pad":{"version":"0.0.1-dirty"}}}\n' > package-lock.json
STATUS3=$(bash "$SCRIPT" "$CONSUMER" "$OUT" 2>/dev/null)
ver3=$(python3 -c "import json;print(json.load(open('$OUT'))['packages']['node_modules/left-pad']['version'])" 2>/dev/null)
check "dirty worktree edit is ignored in favour of origin" "$ver3" "9.9.9"
check "status flags the dirty lockfile" "$(printf '%s' "$STATUS3" | grep -o 'dirty=1')" "dirty=1"
git checkout -q -- package-lock.json

# --- non-git dir must FALL BACK, not fail ----------------------------------------
PLAIN="$TMP/plain"; mkdir -p "$PLAIN"
printf '{"name":"x","packages":{"node_modules/left-pad":{"version":"5.5.5"}}}\n' > "$PLAIN/package-lock.json"
STATUS4=$(bash "$SCRIPT" "$PLAIN" "$OUT" 2>/dev/null)
ver4=$(python3 -c "import json;print(json.load(open('$OUT'))['packages']['node_modules/left-pad']['version'])" 2>/dev/null)
check "non-git dir falls back to the worktree file" "$ver4" "5.5.5"
check "non-git dir says so" "$(printf '%s' "$STATUS4" | grep -o 'ref=worktree')" "ref=worktree"

# --- missing lockfile -> non-zero, no output file --------------------------------
EMPTY="$TMP/empty"; mkdir -p "$EMPTY"
rm -f "$OUT"
bash "$SCRIPT" "$EMPTY" "$OUT" >/dev/null 2>&1
check "missing lockfile exits non-zero" "$?" "1"
check "missing lockfile writes no output" "$([ -f "$OUT" ] && echo yes || echo no)" "no"

echo
echo "scan-lockfile: PASS=$_pass FAIL=$_fail"
[ "$_fail" -eq 0 ]
