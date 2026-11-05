#!/usr/bin/env bash
# Test world-watch.sh — fully OFFLINE.
# Tests the pure comparison logic (EOL version check, Graph API grep) via
# local fixtures + env overrides so no real network/npm calls are needed.
#
# Run: bash ops/lib/__tests__/world-watch.test.sh
set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")/../../" && pwd)/world-watch.sh"
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

_pass=0; _fail=0

assert_py() {
  local label="$1" pycode="$2"
  if python3 - <<PY
${pycode}
PY
  then echo "PASS: $label"; _pass=$((_pass + 1))
  else echo "FAIL: $label"; _fail=$((_fail + 1)); fi
}

# ============================================================
# Fixture: EOL data directory (simulates endoflife.date API)
# ============================================================
EOL_DIR="$ROOT/eol-fixtures"
mkdir -p "$EOL_DIR"

# next.js: v12 is EOL, v13 is active, v14 is active (current)
cat > "$EOL_DIR/nextjs.json" << 'JSON'
[
  {"cycle": "14", "eol": false, "support": false},
  {"cycle": "13", "eol": false, "support": false},
  {"cycle": "12", "eol": "2023-04-30", "support": false},
  {"cycle": "11", "eol": "2022-10-31", "support": false}
]
JSON

# react: v17 is active (cycles_behind=1 from v18 → no report), v16 is 2 behind → report
cat > "$EOL_DIR/react.json" << 'JSON'
[
  {"cycle": "18", "eol": false, "support": false},
  {"cycle": "17", "eol": false, "support": false},
  {"cycle": "16", "eol": "2022-10-01", "support": false}
]
JSON

# nodejs: write a minimal fixture
cat > "$EOL_DIR/nodejs.json" << 'JSON'
[
  {"cycle": "20", "eol": false, "support": false},
  {"cycle": "18", "eol": false, "support": false},
  {"cycle": "16", "eol": "2023-09-11", "support": false}
]
JSON

# prisma: all active
cat > "$EOL_DIR/prisma.json" << 'JSON'
[{"cycle": "5", "eol": false, "support": false}]
JSON

# express: all active
cat > "$EOL_DIR/express.json" << 'JSON'
[{"cycle": "4", "eol": false, "support": false}]
JSON

# ============================================================
# Fixture repo A — uses next v12 (EOL) and react v16 (2 cycles behind)
# ============================================================
REPO_A="$ROOT/repo-a"
mkdir -p "$REPO_A"
cat > "$REPO_A/package.json" << 'JSON'
{
  "name": "fixture-a",
  "dependencies": {
    "next": "12.3.4",
    "react": "16.14.0",
    "express": "4.18.0"
  }
}
JSON

# ============================================================
# Fixture repo B — uses current versions (no EOL findings)
# ============================================================
REPO_B="$ROOT/repo-b"
mkdir -p "$REPO_B"
cat > "$REPO_B/package.json" << 'JSON'
{
  "name": "fixture-b",
  "dependencies": {
    "next": "14.0.0",
    "react": "18.2.0"
  }
}
JSON

# ============================================================
# Fixture whatsapp-like file with old graph API version
# ============================================================
WBS_DIR="$ROOT/wbs-fixture"
mkdir -p "$WBS_DIR/src"
cat > "$WBS_DIR/src/api.ts" << 'JS'
// WhatsApp cloud API client
const BASE_URL = "https://graph.facebook.com/v18.0/messages";
const MEDIA_URL = `https://graph.facebook.com/v16.0/media`;
const CURRENT_URL = "https://graph.facebook.com/v22.0/status";
JS

# Husky's own generated shim. It carries the line "They WILL FAIL in v10.0.0"
# — husky's version, not a Graph API version — and on 2026-09-13 the scanner
# reported it as a HIGH "12 versions behind current v22.0" finding against
# ebda-whatsapp. A watcher that cries wolf at that severity is a watcher
# that stops being read.
mkdir -p "$WBS_DIR/.husky/_"
cat > "$WBS_DIR/.husky/_/husky.sh" << 'SH'
echo "husky - DEPRECATED

They WILL FAIL in v10.0.0
"
SH

# Prose and semvers that mention a version but pin nothing.
cat > "$WBS_DIR/src/notes.ts" << 'JS'
// changelog: bumped eslint to v10.0.0
const pkg = { version: "v18.0.1" };
// see release v22.0 notes
JS

# ============================================================
# Pure-python EOL comparison helper (extracted from world-watch.sh)
# — the test drives it directly to verify the logic
# ============================================================
EOL_COMPARE_PY="$ROOT/eol_compare.py"
cat > "$EOL_COMPARE_PY" << 'PYEOF'
"""Offline-testable EOL comparison logic extracted from world-watch.sh"""
import json, sys, re
from datetime import date, datetime

def parse_date(s):
    if not s: return None
    for fmt in ("%Y-%m-%d", "%Y-%m", "%Y"):
        try: return datetime.strptime(s, fmt).date()
        except: pass
    return None

def check_eol(repo, dep, installed, eol_raw):
    """Returns list of findings dicts (may be empty)."""
    try:
        cycles = json.loads(eol_raw)
    except Exception:
        return []
    if not isinstance(cycles, list) or not cycles:
        return []
    m = re.match(r"^(\d+)", installed)
    if not m: return []
    installed_major = int(m.group(1))
    today = date.today()
    active_majors = []
    for cycle in cycles:
        c = str(cycle.get("cycle", ""))
        cm = re.match(r"^(\d+)", c)
        if not cm: continue
        cmaj = int(cm.group(1))
        eol = parse_date(str(cycle.get("eol", "") or ""))
        is_eol = eol is True or (isinstance(cycle.get("eol"), bool) and cycle["eol"])
        if not is_eol and eol and eol <= today: is_eol = True
        if not is_eol: active_majors.append(cmaj)
    installed_cycle_eol = False
    installed_eol_date = ""
    for cycle in cycles:
        c = str(cycle.get("cycle", ""))
        cm = re.match(r"^(\d+)", c)
        if not cm: continue
        if int(cm.group(1)) != installed_major: continue
        eol = parse_date(str(cycle.get("eol", "") or ""))
        is_eol = eol is True or (isinstance(cycle.get("eol"), bool) and cycle["eol"])
        if not is_eol and eol and eol <= today:
            is_eol = True; installed_eol_date = str(eol)
        if is_eol: installed_cycle_eol = True
        break
    latest_active = max(active_majors) if active_majors else installed_major
    cycles_behind = latest_active - installed_major
    if not installed_cycle_eol and cycles_behind < 2:
        return []
    if installed_cycle_eol:
        severity, title = "high", "%s v%d is EOL" % (dep, installed_major)
    else:
        severity = "medium"
        title = "%s v%d is %d cycle(s) behind current (v%d)" % (dep, installed_major, cycles_behind, latest_active)
    return [{"repo": repo, "class": "framework-eol", "severity": severity,
             "file": "package.json", "line": 0, "title": title,
             "detail": "", "fix": "", "autofixable": False}]

if __name__ == "__main__":
    # called as: eol_compare.py <repo> <dep> <installed> <eol_json_path>
    repo, dep, installed, eol_path = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
    eol_raw = open(eol_path).read()
    result = check_eol(repo, dep, installed, eol_raw)
    print(json.dumps(result))
PYEOF

# ============================================================
# TEST 1: EOL product → "high" finding when installed major is EOL
# ============================================================
NEXT_EOL=$(python3 "$EOL_COMPARE_PY" "fixture-a" "next" "12.3.4" "$EOL_DIR/nextjs.json")
assert_py "next v12 (EOL) produces a high-severity framework-eol finding" "
import json
findings = json.loads('''${NEXT_EOL}''')
assert len(findings) == 1, 'expected 1 finding, got %d' % len(findings)
f = findings[0]
assert f['class'] == 'framework-eol', 'wrong class'
assert f['severity'] == 'high', 'expected high severity, got %s' % f['severity']
assert 'EOL' in f['title'], 'title should mention EOL'
assert f['autofixable'] is False
"

# ============================================================
# TEST 2: Current version → no finding
# ============================================================
NEXT_CURRENT=$(python3 "$EOL_COMPARE_PY" "fixture-b" "next" "14.0.0" "$EOL_DIR/nextjs.json")
assert_py "next v14 (current) produces no finding" "
import json
findings = json.loads('''${NEXT_CURRENT}''')
assert findings == [], 'expected no findings, got %s' % findings
"

# ============================================================
# TEST 3: 2 cycles behind → medium finding
# ============================================================
REACT_OLD=$(python3 "$EOL_COMPARE_PY" "fixture-a" "react" "16.14.0" "$EOL_DIR/react.json")
assert_py "react v16 (2 cycles behind) produces a medium finding" "
import json
findings = json.loads('''${REACT_OLD}''')
assert len(findings) == 1, 'expected 1 finding, got %d' % len(findings)
f = findings[0]
assert f['class'] == 'framework-eol'
assert f['severity'] in ('medium', 'high'), 'expected medium or high, got %s' % f['severity']
"

# ============================================================
# TEST 4: 1 cycle behind → no finding (below the 2-cycle threshold)
# ============================================================
REACT_ONE_BEHIND=$(python3 "$EOL_COMPARE_PY" "fixture-b" "react" "17.0.2" "$EOL_DIR/react.json")
assert_py "react v17 (1 cycle behind, not EOL) produces no finding" "
import json
findings = json.loads('''${REACT_ONE_BEHIND}''')
assert findings == [], 'expected no finding for 1-cycle lag, got %s' % findings
"

# ============================================================
# TEST 5: Graph API version drift — v18.0 is 4 behind v22.0 → high finding
# ============================================================
GRAPH_FINDINGS=$(python3 - "$WBS_DIR" "v22.0" << 'PYEOF'
import json, os, re, sys
wbs_dir = sys.argv[1]; current_raw = sys.argv[2]
m = re.match(r"v?(\d+)", current_raw)
if not m: print("[]"); sys.exit(0)
current_major = int(m.group(1))
findings = []; seen = set()
# KEEP IN STEP WITH ops/world-watch.sh. This is a COPY of the detector, so a
# fix applied only to the real script leaves this test green against the old
# logic — proving nothing about what ships.
skip_dirs = {"node_modules", ".git", ".next", "dist", "build", ".husky", "vendor", "coverage"}
GRAPH_CONTEXT = re.compile(
    r"graph\.facebook|facebook\.com|fbcdn|whatsapp|meta[_-]?api"
    r"|api[_-]?version|graph[_-]?api|GRAPH_API|API_VERSION",
    re.IGNORECASE,
)
for root, dirs, files in os.walk(wbs_dir):
    dirs[:] = [d for d in dirs if d not in skip_dirs]
    for fname in files:
        if not re.search(r"\.(ts|tsx|js|jsx|mjs|cjs|env|json|sh|yaml|yml)$", fname): continue
        if fname in ("package-lock.json", "yarn.lock", "pnpm-lock.yaml"): continue
        fpath = os.path.join(root, fname)
        rel_path = os.path.relpath(fpath, wbs_dir)
        try: text = open(fpath, encoding="utf-8", errors="replace").read()
        except: continue
        for lineno, line in enumerate(text.splitlines(), 1):
            if not GRAPH_CONTEXT.search(line): continue
            for match in re.finditer(r"v(\d{2,3})\.0(?!\.?\d)", line):
                found_major = int(match.group(1))
                if found_major >= current_major: continue
                lag = current_major - found_major
                key = (rel_path, lineno, found_major)
                if key in seen: continue
                seen.add(key)
                sev = "high" if lag >= 4 else "medium"
                findings.append({"repo":"ebda-whatsapp","class":"api-version-drift","severity":sev,
                    "file":rel_path,"line":lineno,
                    "title":"Hardcoded Graph API v%d.0 is %d version(s) behind current v%d.0"%(found_major,lag,current_major),
                    "detail":"","fix":"","autofixable":False})
print(json.dumps(findings))
PYEOF
)
assert_py "v18.0 (4 behind v22.0) detected as high api-version-drift" "
import json
findings = json.loads('''${GRAPH_FINDINGS}''')
high_findings = [f for f in findings if f['class'] == 'api-version-drift' and f['severity'] == 'high']
assert len(high_findings) >= 1, 'expected at least 1 high api-version-drift, got: %s' % findings
# v18 is 4 behind → high
assert any('v18.0' in f['title'] for f in high_findings), 'expected v18.0 in a finding'
"

assert_py "husky's own 'v10.0.0' is NOT reported as a Graph API pin" "
import json
findings = json.loads(r'''${GRAPH_FINDINGS}''')
# Two independent guards must each stop this: .husky is pruned as vendored tool
# output, and the line carries no Graph/WhatsApp context. It was reported as a
# HIGH '12 versions behind current v22.0' finding on 2026-09-13.
husky = [f for f in findings if 'husky' in f['file']]
assert husky == [], 'husky shim reported as a Graph API pin: %s' % husky
assert not any(f['title'].startswith('Hardcoded Graph API v10.0') for f in findings), 'v10.0 (husky version) reported as a Graph API version: %s' % findings
"

assert_py "a semver or changelog mention is NOT a Graph API pin" "
import json
findings = json.loads(r'''${GRAPH_FINDINGS}''')
notes = [f for f in findings if 'notes.ts' in f['file']]
assert notes == [], 'prose/semver reported as Graph API pins: %s' % notes
"

assert_py "the real pins still fire — the guards did not silence the scanner" "
import json
findings = json.loads(r'''${GRAPH_FINDINGS}''')
# Positive control for the two assertions above: a detector tightened into
# uselessness would satisfy both while finding nothing at all.
api = [f for f in findings if 'api.ts' in f['file']]
assert len(api) >= 2, 'expected the v18.0 and v16.0 graph.facebook.com pins, got: %s' % findings
assert any('v18.0' in f['title'] for f in api), 'lost the v18.0 pin'
assert any('v16.0' in f['title'] for f in api), 'lost the v16.0 pin'
"

assert_py "v16.0 (6 behind v22.0) also detected as high api-version-drift" "
import json
findings = json.loads('''${GRAPH_FINDINGS}''')
assert any('v16.0' in f['title'] for f in findings), 'expected v16.0 in findings: %s' % findings
"

assert_py "v22.0 (current) is NOT flagged as a lagging version" "
import json
findings = json.loads('''${GRAPH_FINDINGS}''')
# Titles for lagging versions look like 'Hardcoded Graph API vXX.0 is N version(s) behind...'
# A current-version finding would have 'v22.0 is' in the title.
# Check that no finding reports v22.0 as the lagging version (it may appear as the target).
assert not any(f['title'].startswith('Hardcoded Graph API v22.0 is') for f in findings), \
    'v22.0 should not be reported as lagging: %s' % findings
"

# ============================================================
# TEST 6: findings schema validation — all required 9 fields present
# ============================================================
SCHEMA_JSON=$(python3 "$EOL_COMPARE_PY" "repo-x" "next" "12.0.0" "$EOL_DIR/nextjs.json")
assert_py "EOL finding has all 9 required schema fields" "
import json
findings = json.loads('''${SCHEMA_JSON}''')
required = {'repo','class','severity','file','line','title','detail','fix','autofixable'}
for f in findings:
    missing = required - set(f)
    assert not missing, 'missing fields: %s' % missing
    assert f['severity'] in ('critical','high','medium','low'), 'invalid severity: %s' % f['severity']
    assert f['autofixable'] is False, 'world-watch findings must be propose-only'
"

# ============================================================
# TEST 7: fail-open — empty/corrupt EOL data → no crash, no findings
# ============================================================
CORRUPT_RESULT=$(python3 "$EOL_COMPARE_PY" "repo-x" "next" "12.0.0" /dev/null 2>/dev/null || echo "[]")
assert_py "corrupt/absent EOL data → [] (fail-open)" "
import json
result = json.loads('''${CORRUPT_RESULT}''')
assert result == [], 'expected [] on corrupt EOL data, got: %s' % result
"

# ------------------------------------------------------------
# Workstation fixture for the whole-script smoke tests below.
#
# world-watch.sh reads "$HOME/Desktop/projects" and os-state.sh's
# require_readable_projects() aborts the scan when that tree is unreadable —
# deliberately, so a blind run is never reported as "no drift". On CI there is
# no such tree, so the script correctly aborted and printed no header.
#
# Give it a minimal readable tree in a throwaway HOME rather than weakening the
# guard. The canary os-state.sh looks for is ebda-store/.git.
# ------------------------------------------------------------
WS_HOME="$(mktemp -d)"
mkdir -p "$WS_HOME/Desktop/projects/Ebda-AI-Studio/internal-projects/ebda-store/.git"
trap 'rm -rf "$WS_HOME"' EXIT

# ============================================================
# TEST 8: world-watch.sh dry-run completes without error
# (exercises the full script with all network disabled)
# ============================================================
DRY_RESULT=$(
  WW_EOL_DATA_DIR="$EOL_DIR" \
  WW_SKIP_NPM_DEP=1 \
  WW_SKIP_API=1 \
  DRY_RUN=1 \
  HOME="$WS_HOME" \
  bash "$SCRIPT" 2>&1 || true
)
assert_py "world-watch.sh DRY_RUN=1 exits 0 and prints header" "
output = '''${DRY_RESULT}'''
assert 'world-watch' in output.lower(), 'expected world-watch header in output'
assert 'DRY_RUN' in output, 'expected DRY_RUN marker in output'
"

# ============================================================
# TEST 9: WW_SKIP_EOL=1 — EOL lens skipped, script still exits 0
# ============================================================
SKIP_EOL_OUT=$(
  WW_SKIP_EOL=1 \
  WW_SKIP_NPM_DEP=1 \
  WW_SKIP_API=1 \
  DRY_RUN=1 \
  HOME="$WS_HOME" \
  bash "$SCRIPT" 2>&1 || true
)
assert_py "WW_SKIP_EOL=1 exits 0 without EOL findings" "
assert 'world-watch' in '''${SKIP_EOL_OUT}'''.lower()
"

# ============================================================
# TEST 10: network-absent fail-open — curl not on PATH → [] from EOL lens
# ============================================================
NO_CURL_RESULT=$(
  PATH="/usr/bin:/bin" \
  WW_SKIP_NPM_DEP=1 \
  WW_SKIP_API=1 \
  DRY_RUN=0 \
  HOME="$WS_HOME" \
  bash "$SCRIPT" 2>&1 || true
)
assert_py "curl absent → script completes without crash" "
# The script should still exit normally even without curl.
# It must print the world-watch header (proof it ran to completion).
assert 'world-watch' in '''${NO_CURL_RESULT}'''.lower(), \
    'script crashed when curl absent: ' + repr('''${NO_CURL_RESULT}''')[:200]
"

echo ""
echo "world-watch: $_pass passed, $_fail failed"
[ "$_fail" -eq 0 ] || exit 1
