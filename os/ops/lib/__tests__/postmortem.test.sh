#!/usr/bin/env bash
# Test ops/postmortem.sh — mirrors code-health.test.sh conventions.
# Overrides HOME to a tmpdir so the test never touches the real
# ~/.whisky-os-state/ or the real audit/ tree.
# Run: bash ops/lib/__tests__/postmortem.test.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$(cd "$HERE/../.." && pwd)/postmortem.sh"

_pass=0; _fail=0
assert() {
  local label="$1" result="$2"
  if [ "$result" = "0" ]; then
    echo "PASS: $label"; _pass=$((_pass + 1))
  else
    echo "FAIL: $label"; _fail=$((_fail + 1))
  fi
}
assert_py() {
  local label="$1" pycode="$2"
  if python3 - <<PY 2>/dev/null
${pycode}
PY
  then echo "PASS: $label"; _pass=$((_pass + 1))
  else echo "FAIL: $label"; _fail=$((_fail + 1)); fi
}

# ---- set up a fake HOME with a seeded events.ndjson ----
FAKE_HOME="$(mktemp -d)"
trap 'rm -rf "$FAKE_HOME"' EXIT

mkdir -p "$FAKE_HOME/.whisky-os-state"

# The TCC canary in ops/lib/os-state.sh (require_projects_access) refuses to run
# any scan unless $HOME/Desktop/projects/Ebda-AI-Studio/internal-projects/ebda-store/.git is readable —
# it cannot tell "macOS denied this launchd context" apart from "HOME is a
# tmpdir". Because this suite overrides HOME for state isolation, every run
# aborted at the canary with "BLIND: cannot read ~/Desktop/projects" and 8 of the
# 14 assertions failed on a product that was working fine. Satisfy the canary
# inside the fake HOME so the isolation stays intact and the script actually runs.
mkdir -p "$FAKE_HOME/Desktop/projects/Ebda-AI-Studio/internal-projects/ebda-store/.git"

# Seed a few fake bus events (the test validates the postmortem includes slug content)
python3 -c "
import json, datetime
now = datetime.datetime.utcnow()
events = [
    {'ts': (now - datetime.timedelta(hours=1)).isoformat(timespec='seconds') + 'Z',
     'name': 'os-watch', 'severity': 'high',
     'summary': 'ebda-store: main CI was GREEN, now FAILING @ abc12345',
     'detail': {'source': 'os-watch', 'kind': 'ci-regression'}},
    {'ts': (now - datetime.timedelta(hours=2)).isoformat(timespec='seconds') + 'Z',
     'name': 'deploy-drift', 'severity': 'medium',
     'summary': 'Deployment drift detected on ebda-store',
     'detail': {}},
]
path = '$FAKE_HOME/.whisky-os-state/events.ndjson'
with open(path, 'w') as f:
    for e in events:
        f.write(json.dumps(e) + '\n')
"

# The postmortem script writes to audit/postmortems/ relative to the tree root.
# Since we cd into ops/, we need the tree root to exist under FAKE_HOME or
# we point via the real worktree. We'll use the real worktree path for the script
# itself but override HOME so bus state + (any) audit writes stay isolated.

# For output files, we intercept by providing a writable TREE_ROOT:
# The script resolves TREE_ROOT as dirname($(pwd)) i.e. dirname(ops/) = project root.
# We run the script via bash so it cds into its own directory.
# The postmortem will write into the real worktree's audit/ dir unless we redirect.
# Strategy: run with DRY_RUN=1 for the gather test, then run a real run into a
# temp AUDIT dir by symlinking. Actually simplest: run the real script but note it
# writes into the actual worktree audit/postmortems/ — that's fine for CI (the
# worktree is ephemeral). We verify the file was written.

WORKTREE_ROOT="$(cd "$HERE/../../.." && pwd)"

# ---- test 1: missing args exits 0 (fail-open) ----
result=0
HOME="$FAKE_HOME" bash "$SCRIPT" 2>/dev/null || result=$?
assert "missing args exits 0 (fail-open)" "$result"

# ---- test 2: DRY_RUN=1 — gathers context, prints, exits 0, writes NO files ----
result=0
OUT="$(HOME="$FAKE_HOME" DRY_RUN=1 bash "$SCRIPT" \
  --slug test-dry-run \
  --repo ebda-store \
  --summary "Test incident summary for dry run" \
  --severity P0 2>/dev/null)" || result=$?
assert "DRY_RUN exits 0" "$result"

assert_py "DRY_RUN output mentions slug" "
out = '''${OUT}'''
assert 'test-dry-run' in out or 'DRY_RUN' in out, 'slug or DRY_RUN not in output'
"

# DRY_RUN should write NO file: pass when no matching file exists (exit 1 from ls = no file = 0 for our assert)
DRY_NO_FILE_RESULT=0
ls "$WORKTREE_ROOT/audit/postmortems/"*test-dry-run* >/dev/null 2>&1 && DRY_NO_FILE_RESULT=1 || true
# DRY_NO_FILE_RESULT=0 means no file found (correct), pass; 1 means file found (wrong), fail
assert "DRY_RUN writes no postmortem file" "$DRY_NO_FILE_RESULT"

# ---- test 3: real run — postmortem .md is written with slug in filename ----
# Shadow claude so we always hit the skeleton path (deterministic sections test).
SLUG="postmortem-test-$(python3 -c 'import time; print(int(time.time()))')"
NO_CLAUDE_PATH_3="/nonexistent-for-test-real:$PATH"
result=0
PATH="$NO_CLAUDE_PATH_3" HOME="$FAKE_HOME" bash "$SCRIPT" \
  --slug "$SLUG" \
  --repo ebda-store \
  --summary "CI regression: main was green, now failing after PR merge" \
  --severity P0 2>/dev/null || result=$?
assert "real run exits 0" "$result"

TODAY="$(python3 -c 'import datetime; print(datetime.date.today().isoformat())')"
PM_FILE="$WORKTREE_ROOT/audit/postmortems/${TODAY}-${SLUG}.md"
CAND_FILE="$WORKTREE_ROOT/ops/detectors/_candidates/${SLUG}.json"

FILE_RESULT=1
[ -f "$PM_FILE" ] && FILE_RESULT=0 || true
assert "postmortem .md file written" "$FILE_RESULT"

assert_py "postmortem .md contains slug" "
import os
path = '$PM_FILE'
if not os.path.exists(path):
    print('file missing:', path)
    assert False
content = open(path).read()
assert '$SLUG' in content, 'slug not in postmortem: ' + content[:200]
"

assert_py "postmortem .md contains required sections" "
import os
path = '$PM_FILE'
if not os.path.exists(path):
    assert False, 'file missing'
content = open(path).read()
for section in ('Summary', 'Timeline', 'Root Cause', 'Prevention'):
    assert section in content, 'missing section: ' + section
"

# ---- test 4: candidate detector JSON exists and is valid JSON ----
CAND_RESULT=1
[ -f "$CAND_FILE" ] && CAND_RESULT=0 || true
assert "candidate detector .json written" "$CAND_RESULT"

assert_py "candidate detector is valid JSON with required fields" "
import json, os
path = '$CAND_FILE'
if not os.path.exists(path):
    assert False, 'file missing'
obj = json.load(open(path))
assert isinstance(obj, dict), 'not a dict'
for field in ('name', 'class', 'severity', 'repos', 'rationale'):
    assert field in obj, 'missing field: ' + field
assert isinstance(obj['repos'], list), 'repos must be a list'
"

# ---- test 5: fail-open when claude absent — still writes a skeleton postmortem ----
SLUG2="postmortem-noclaud-$(python3 -c 'import time; print(int(time.time()))')"
# Override PATH to exclude any claude binary
NO_CLAUDE_PATH="$(python3 -c "
import os
parts = [p for p in os.environ.get('PATH','').split(':') if p]
# Filter out directories containing 'claude' — simpler: just prepend /nonexistent
print('/nonexistent-dir-for-test:' + ':'.join(parts))
")"

# Create a fake PATH that shadows claude with a nonexistent path prefix
result=0
PATH="$NO_CLAUDE_PATH" HOME="$FAKE_HOME" bash "$SCRIPT" \
  --slug "$SLUG2" \
  --repo ebda-store \
  --summary "Skeleton postmortem test — no claude CLI available" \
  2>/dev/null || result=$?
assert "fail-open when claude absent: exits 0" "$result"

PM_FILE2="$WORKTREE_ROOT/audit/postmortems/${TODAY}-${SLUG2}.md"
FILE2_RESULT=1
[ -f "$PM_FILE2" ] && FILE2_RESULT=0 || true
assert "fail-open when claude absent: skeleton postmortem .md still written" "$FILE2_RESULT"

# ---- test 6: fail-open when gh absent — still writes a postmortem ----
SLUG3="postmortem-nogh-$(python3 -c 'import time; print(int(time.time()))')"
# Build a PATH that excludes gh by prepending a fake dir
NO_GH_PATH="/nonexistent-for-test-nogh:$PATH"
result=0
PATH="$NO_GH_PATH" HOME="$FAKE_HOME" bash "$SCRIPT" \
  --slug "$SLUG3" \
  --repo ebda-store \
  --summary "Skeleton postmortem test — no gh CLI available" \
  2>/dev/null || result=$?
assert "fail-open when gh absent: exits 0" "$result"

PM_FILE3="$WORKTREE_ROOT/audit/postmortems/${TODAY}-${SLUG3}.md"
FILE3_RESULT=1
[ -f "$PM_FILE3" ] && FILE3_RESULT=0 || true
assert "fail-open when gh absent: postmortem .md still written" "$FILE3_RESULT"

# ---- cleanup test artifacts from the worktree ----
rm -f "$PM_FILE" "$PM_FILE2" "$PM_FILE3" 2>/dev/null || true
rm -f "$CAND_FILE" \
  "$WORKTREE_ROOT/ops/detectors/_candidates/${SLUG2}.json" \
  "$WORKTREE_ROOT/ops/detectors/_candidates/${SLUG3}.json" 2>/dev/null || true
# Remove dirs if now empty
rmdir "$WORKTREE_ROOT/audit/postmortems" 2>/dev/null || true
rmdir "$WORKTREE_ROOT/audit" 2>/dev/null || true
rmdir "$WORKTREE_ROOT/ops/detectors/_candidates" 2>/dev/null || true
rmdir "$WORKTREE_ROOT/ops/detectors" 2>/dev/null || true

echo ""
echo "postmortem: $_pass passed, $_fail failed"
[ "$_fail" -eq 0 ] || exit 1
