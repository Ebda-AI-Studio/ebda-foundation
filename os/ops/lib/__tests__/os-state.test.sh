#!/usr/bin/env bash
# Test the write_status helper: valid JSON, right keys, bad-detail resilience.
set -euo pipefail
HOME="$(mktemp -d)"; export HOME
. "$(dirname "$0")/../os-state.sh"

write_status demo true "all good" '{"n":3}'
f="$HOME/.whisky-os-state/demo-status.json"
[ -f "$f" ] || { echo "FAIL: no file"; exit 1; }
python3 - "$f" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
assert d["ok"]=="true", d
assert d["summary"]=="all good", d
assert d["detail"]["n"]==3, d
assert d["checked_at"].endswith("Z"), d
print("PASS")
PY

# bad detail must not crash + must still write (raw-wrapped)
write_status demo2 warn "weird" 'not-json'
python3 - "$HOME/.whisky-os-state/demo2-status.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
assert d["ok"]=="warn" and d["detail"]["raw"]=="not-json", d
print("PASS2")
PY

# --- repo_commits_behind: the staleness signal every scanner leans on -----------
# Regression guard for 2026-08-18, when dream-research reported four Next.js CVEs
# against a checkout 2 commits behind origin — advisories already fixed upstream.
_rcb="$(mktemp -d)"
git config --global init.defaultBranch main >/dev/null 2>&1 || true
git init -q --bare "$_rcb/origin" 2>/dev/null
git clone -q "$_rcb/origin" "$_rcb/w" 2>/dev/null
( cd "$_rcb/w" && git config user.email t@t.t && git config user.name t \
  && echo one > f && git add f && git commit -qm one && git push -q origin HEAD:main ) 2>/dev/null
git clone -q "$_rcb/origin" "$_rcb/stale" 2>/dev/null
( cd "$_rcb/w" && echo two > f && git commit -qam two && git push -q origin HEAD:main ) 2>/dev/null

[ "$(repo_commits_behind "$_rcb/stale")" = "1" ] || { echo "FAIL: stale checkout not detected"; exit 1; }
( cd "$_rcb/stale" && git merge -q --ff-only origin/main ) 2>/dev/null
[ "$(repo_commits_behind "$_rcb/stale")" = "0" ] || { echo "FAIL: fresh checkout misreported"; exit 1; }
# fail-soft: a non-repo or empty input must never block a scan
[ "$(repo_commits_behind "$_rcb/nope")" = "0" ] || { echo "FAIL: non-repo not fail-soft"; exit 1; }
[ "$(repo_commits_behind "")" = "0" ] || { echo "FAIL: empty input not fail-soft"; exit 1; }
rm -rf "$_rcb"
echo "PASS3 (repo_commits_behind: stale=1, fresh=0, fail-soft)"
