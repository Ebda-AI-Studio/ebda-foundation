#!/usr/bin/env bash
# Test findings-normalize.py via its CLI.
# Run: bash ops/lib/__tests__/findings-normalize.test.sh
set -euo pipefail

SCRIPT="$(dirname "$0")/../findings-normalize.py"
TMPDIR_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

_pass=0
_fail=0

assert_py() {
  local label="$1" pycode="$2"
  if python3 - <<PY
${pycode}
PY
  then
    echo "PASS: $label"
    _pass=$((_pass + 1))
  else
    echo "FAIL: $label"
    _fail=$((_fail + 1))
  fi
}

# Write fixture JSON via python3 to avoid shell quoting issues with special chars
# (backticks, quotes) inside JSON strings.
write_fixture() {
  local name="$1"
  local pycode="$2"
  python3 - "$TMPDIR_ROOT/${name}.json" <<PY
import json, sys
data = ${pycode}
json.dump(data, open(sys.argv[1], "w"))
PY
  echo "$TMPDIR_ROOT/${name}.json"
}

# ---------------------------------------------------------------------------
# TEST 1: 5 findings same (repo,class,title) different file/line → 1 group, count=5, 5 sites
# ---------------------------------------------------------------------------
F1="$(write_fixture t1 '[
    {"repo":"r","class":"c","severity":"medium","file":"a.ts","line":1,"title":"unbounded findMany","detail":None,"fix":None,"autofixable":False},
    {"repo":"r","class":"c","severity":"medium","file":"b.ts","line":2,"title":"unbounded findMany","detail":None,"fix":None,"autofixable":False},
    {"repo":"r","class":"c","severity":"medium","file":"c.ts","line":3,"title":"unbounded findMany","detail":None,"fix":None,"autofixable":False},
    {"repo":"r","class":"c","severity":"medium","file":"d.ts","line":4,"title":"unbounded findMany","detail":None,"fix":None,"autofixable":False},
    {"repo":"r","class":"c","severity":"medium","file":"e.ts","line":5,"title":"unbounded findMany","detail":None,"fix":None,"autofixable":False},
]')"

RESULT1="$(python3 "$SCRIPT" "$F1" --json)"
assert_py "5 same-key findings → 1 group, count=5, 5 sites" "
import json
r = json.loads('''${RESULT1}''')
assert r['counts']['grouped'] == 1, 'grouped=%d' % r['counts']['grouped']
g = r['grouped'][0]
assert g['count'] == 5, 'count=%d' % g['count']
assert len(g['sites']) == 5, 'sites=%d' % len(g['sites'])
"

# ---------------------------------------------------------------------------
# TEST 2: severity "unknown" and "" → needs_rule, NOT grouped
# ---------------------------------------------------------------------------
F2="$(write_fixture t2 '[
    {"repo":"r","class":"c","severity":"unknown","file":"a.ts","line":1,"title":"some finding","detail":None,"fix":None,"autofixable":False},
    {"repo":"r","class":"c","severity":"","file":"b.ts","line":2,"title":"another finding","detail":None,"fix":None,"autofixable":False},
    {"repo":"r","class":"c","severity":"high","file":"c.ts","line":3,"title":"real finding","detail":None,"fix":None,"autofixable":False},
]')"

RESULT2="$(python3 "$SCRIPT" "$F2" --json)"
assert_py "unknown+empty severity → needs_rule (not grouped)" "
import json
r = json.loads('''${RESULT2}''')
assert r['counts']['needs_rule'] == 2, 'needs_rule=%d' % r['counts']['needs_rule']
assert r['counts']['grouped'] == 1, 'grouped=%d' % r['counts']['grouped']
"

# ---------------------------------------------------------------------------
# TEST 3: titles differing only by version / GHSA id / quoted path → same group
# Two version-number titles → 1 group; two GHSA titles → 1 group;
# two backtick-quoted-path titles (same repo) → 1 group. Total = 3 groups.
# ---------------------------------------------------------------------------
F3="$(write_fixture t3 '[
    {"repo":"r","class":"c","severity":"medium","file":"a.ts","line":1,"title":"prototype pollution in 2.3.1","detail":None,"fix":None,"autofixable":False},
    {"repo":"r","class":"c","severity":"medium","file":"b.ts","line":2,"title":"prototype pollution in 3.0.0","detail":None,"fix":None,"autofixable":False},
    {"repo":"r","class":"c2","severity":"medium","file":"c.ts","line":3,"title":"vuln ghsa-abcd-efgh-ijkl in dep","detail":None,"fix":None,"autofixable":False},
    {"repo":"r","class":"c2","severity":"medium","file":"d.ts","line":4,"title":"vuln ghsa-xxxx-yyyy-zzzz in dep","detail":None,"fix":None,"autofixable":False},
    {"repo":"r","class":"c3","severity":"medium","file":"e.ts","line":5,"title":"unsafe access to \x60some/path/file.ts\x60","detail":None,"fix":None,"autofixable":False},
    {"repo":"r","class":"c3","severity":"medium","file":"f.ts","line":6,"title":"unsafe access to \x60other/path/util.ts\x60","detail":None,"fix":None,"autofixable":False},
]')"

RESULT3="$(python3 "$SCRIPT" "$F3" --json)"
assert_py "version/GHSA/quoted-path variants → 3 groups of 2 (not 6)" "
import json
r = json.loads('''${RESULT3}''')
assert r['counts']['grouped'] == 3, 'grouped=%d (expected 3)' % r['counts']['grouped']
counts = sorted([g['count'] for g in r['grouped']])
assert counts == [2, 2, 2], 'counts=%s (expected [2,2,2])' % counts
"

# ---------------------------------------------------------------------------
# TEST 4: suppression file → matching finding goes to suppressed, not grouped
# ---------------------------------------------------------------------------
F4="$(write_fixture t4 '[
    {"repo":"r","class":"c","severity":"high","file":"a.ts","line":1,"title":"some title","detail":None,"fix":None,"autofixable":False},
    {"repo":"r","class":"c","severity":"high","file":"b.ts","line":2,"title":"other title","detail":None,"fix":None,"autofixable":False},
]')"
SUPP4="$TMPDIR_ROOT/supp4.json"
python3 - "$SUPP4" <<'PY'
import json, sys
json.dump([{"repo": "r", "class": "c", "title": "some title"}], open(sys.argv[1], "w"))
PY

RESULT4="$(python3 "$SCRIPT" "$F4" --suppressions "$SUPP4" --json)"
assert_py "suppressed finding not in grouped" "
import json
r = json.loads('''${RESULT4}''')
assert r['counts']['suppressed'] == 1, 'suppressed=%d' % r['counts']['suppressed']
assert r['counts']['grouped'] == 1, 'grouped=%d' % r['counts']['grouped']
"

# ---------------------------------------------------------------------------
# TEST 5: mixed severities in same group → highest severity wins
# ---------------------------------------------------------------------------
F5="$(write_fixture t5 '[
    {"repo":"r","class":"c","severity":"low","file":"a.ts","line":1,"title":"mixed sev finding","detail":None,"fix":None,"autofixable":False},
    {"repo":"r","class":"c","severity":"high","file":"b.ts","line":2,"title":"mixed sev finding","detail":None,"fix":None,"autofixable":False},
]')"

RESULT5="$(python3 "$SCRIPT" "$F5" --json)"
assert_py "mixed severity group → severity is high (highest wins)" "
import json
r = json.loads('''${RESULT5}''')
assert r['counts']['grouped'] == 1, 'grouped=%d' % r['counts']['grouped']
g = r['grouped'][0]
assert g['severity'] == 'high', 'severity=%s' % g['severity']
assert g['count'] == 2, 'count=%d' % g['count']
"

# ---------------------------------------------------------------------------
# TEST 6: suppressions accept MULTIPLE paths (version-controlled baseline +
# mutable state file) and union them.
#
# WHY: deliberate, reviewed suppressions belong in git so they arrive with a
# rationale and survive review; auto-suppressions written by acceptance-feedback
# from wontfix issues belong in mutable state. Both must apply.
# ---------------------------------------------------------------------------
python3 - "$TMPDIR_ROOT/base.json" <<'PYEOF'
import json, sys
json.dump({"suppress":[{"repo":"r","class":"c","title":"baseline finding","_comment":"why"}]}, open(sys.argv[1],"w"))
PYEOF
python3 - "$TMPDIR_ROOT/state.json" <<'PYEOF'
import json, sys
json.dump({"suppress":[{"repo":"r","class":"c","title":"state finding"}]}, open(sys.argv[1],"w"))
PYEOF
printf 'not json at all' > "$TMPDIR_ROOT/corrupt.json"

assert_py "load_suppressions unions a list of paths" "
import importlib.util, os
spec = importlib.util.spec_from_file_location('fn', '$(dirname "$0")/../findings-normalize.py')
fn = importlib.util.module_from_spec(spec); spec.loader.exec_module(fn)
supp = fn.load_suppressions(['$TMPDIR_ROOT/base.json', '$TMPDIR_ROOT/state.json'])
assert len(supp) == 2, supp
findings = [
  {'repo':'r','class':'c','severity':'high','file':'a.ts','line':1,'title':'baseline finding'},
  {'repo':'r','class':'c','severity':'high','file':'b.ts','line':2,'title':'state finding'},
  {'repo':'r','class':'c','severity':'high','file':'c.ts','line':3,'title':'kept finding'},
]
res = fn.normalize(findings, supp)
assert res['counts']['suppressed'] == 2, res['counts']
assert [g['title'] for g in res['grouped']] == ['kept finding'], res['grouped']
"

assert_py "a single path string still works (back-compat)" "
import importlib.util
spec = importlib.util.spec_from_file_location('fn', '$(dirname "$0")/../findings-normalize.py')
fn = importlib.util.module_from_spec(spec); spec.loader.exec_module(fn)
assert len(fn.load_suppressions('$TMPDIR_ROOT/base.json')) == 1
"

assert_py "missing + corrupt paths FAIL OPEN — they hide nothing" "
import importlib.util
spec = importlib.util.spec_from_file_location('fn', '$(dirname "$0")/../findings-normalize.py')
fn = importlib.util.module_from_spec(spec); spec.loader.exec_module(fn)
# a corrupt baseline must not take the valid state file down with it
supp = fn.load_suppressions(['$TMPDIR_ROOT/corrupt.json', '$TMPDIR_ROOT/nope.json', '$TMPDIR_ROOT/state.json'])
assert len(supp) == 1, supp
assert fn.load_suppressions(['$TMPDIR_ROOT/nope.json']) == set()
assert fn.load_suppressions(None) == set()
assert fn.load_suppressions([]) == set()
"

# ---------------------------------------------------------------------------
# TEST 7: suppression by FILE survives a scanner rewording the title.
#
# WHY: on 2026-08-18 generateSectionPalette was suppressed with evidence, then
# reappeared the next scan because the LLM pass reworded its title from
# "generateSectionPalette() is 104 lines" to "generateSectionPalette() — 104
# lines". Title-keyed suppression silently lapses exactly when the scanner is
# most confident it has something new to say.
# ---------------------------------------------------------------------------
python3 - "$TMPDIR_ROOT/byfile.json" <<'PYEOF'
import json, sys
json.dump({"suppress":[
  {"repo":"r","class":"overcomplexity","file":"src/utils/color.ts","_comment":"lookup table"}
]}, open(sys.argv[1],"w"))
PYEOF

assert_py "suppression by file ignores a reworded title" "
import importlib.util
spec = importlib.util.spec_from_file_location('fn', '$(dirname "$0")/../findings-normalize.py')
fn = importlib.util.module_from_spec(spec); spec.loader.exec_module(fn)
supp = fn.load_suppressions('$TMPDIR_ROOT/byfile.json')
before = [{'repo':'r','class':'overcomplexity','severity':'low','file':'src/utils/color.ts','line':728,'title':'generateSectionPalette() is 104 lines'}]
after  = [{'repo':'r','class':'overcomplexity','severity':'low','file':'src/utils/color.ts','line':728,'title':'generateSectionPalette() — 104 lines'}]
assert fn.normalize(before, supp)['counts']['suppressed'] == 1, 'original wording not suppressed'
assert fn.normalize(after,  supp)['counts']['suppressed'] == 1, 'REWORDED title escaped the suppression'
"

assert_py "file-keyed suppression is still scoped to repo AND class" "
import importlib.util
spec = importlib.util.spec_from_file_location('fn', '$(dirname "$0")/../findings-normalize.py')
fn = importlib.util.module_from_spec(spec); spec.loader.exec_module(fn)
supp = fn.load_suppressions('$TMPDIR_ROOT/byfile.json')
other_repo  = [{'repo':'other','class':'overcomplexity','severity':'low','file':'src/utils/color.ts','line':1,'title':'x'}]
other_class = [{'repo':'r','class':'duplication','severity':'low','file':'src/utils/color.ts','line':1,'title':'x'}]
other_file  = [{'repo':'r','class':'overcomplexity','severity':'low','file':'src/other.ts','line':1,'title':'x'}]
for label, f in (('repo',other_repo),('class',other_class),('file',other_file)):
    assert fn.normalize(f, supp)['counts']['suppressed'] == 0, 'over-suppressed across ' + label
"

assert_py "title-keyed entries still work (back-compat)" "
import importlib.util
spec = importlib.util.spec_from_file_location('fn', '$(dirname "$0")/../findings-normalize.py')
fn = importlib.util.module_from_spec(spec); spec.loader.exec_module(fn)
supp = fn.load_suppressions('$TMPDIR_ROOT/base.json')
f = [{'repo':'r','class':'c','severity':'low','file':'any.ts','line':1,'title':'baseline finding'}]
assert fn.normalize(f, supp)['counts']['suppressed'] == 1
"

# ---------------------------------------------------------------------------
# TEST 8: a file-keyed suppression must NOT swallow unrelated findings in the
# same file. Keying on (repo, class, file) alone suppressed an unreviewed
# "GET() nesting depth 6" that merely shared a route file with a reviewed
# POST() finding — over-suppression is worse than the fragility it replaced.
# ---------------------------------------------------------------------------
python3 - "$TMPDIR_ROOT/bysymbol.json" <<'PYEOF'
import json, sys
json.dump({"suppress":[
  {"repo":"r","class":"overcomplexity","file":"src/api/route.ts","symbol":"POST()","_comment":"field mapping"}
]}, open(sys.argv[1],"w"))
PYEOF

assert_py "symbol-scoped entry suppresses only the reviewed symbol" "
import importlib.util
spec = importlib.util.spec_from_file_location('fn', '$(dirname "$0")/../findings-normalize.py')
fn = importlib.util.module_from_spec(spec); spec.loader.exec_module(fn)
supp = fn.load_suppressions('$TMPDIR_ROOT/bysymbol.json')
findings = [
  {'repo':'r','class':'overcomplexity','severity':'low','file':'src/api/route.ts','line':1,'title':'POST() flagged at 37 branches — mostly field mapping'},
  {'repo':'r','class':'overcomplexity','severity':'low','file':'src/api/route.ts','line':9,'title':'GET() nesting depth 6'},
]
res = fn.normalize(findings, supp)
assert res['counts']['suppressed'] == 1, 'expected exactly 1 suppressed, got %d' % res['counts']['suppressed']
kept = [g['title'] for g in res['grouped']]
assert kept == ['GET() nesting depth 6'], kept
"

assert_py "symbol-scoped entry survives a reworded title for that symbol" "
import importlib.util
spec = importlib.util.spec_from_file_location('fn', '$(dirname "$0")/../findings-normalize.py')
fn = importlib.util.module_from_spec(spec); spec.loader.exec_module(fn)
supp = fn.load_suppressions('$TMPDIR_ROOT/bysymbol.json')
reworded = [{'repo':'r','class':'overcomplexity','severity':'low','file':'src/api/route.ts','line':1,'title':'POST() is 120 lines with 37 branches'}]
assert fn.normalize(reworded, supp)['counts']['suppressed'] == 1
"

assert_py "a file entry with NO symbol still suppresses the whole file (documented blunt form)" "
import importlib.util
spec = importlib.util.spec_from_file_location('fn', '$(dirname "$0")/../findings-normalize.py')
fn = importlib.util.module_from_spec(spec); spec.loader.exec_module(fn)
supp = fn.load_suppressions('$TMPDIR_ROOT/byfile.json')
two = [
  {'repo':'r','class':'overcomplexity','severity':'low','file':'src/utils/color.ts','line':1,'title':'a()'},
  {'repo':'r','class':'overcomplexity','severity':'low','file':'src/utils/color.ts','line':2,'title':'b()'},
]
assert fn.normalize(two, supp)['counts']['suppressed'] == 2
"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "findings-normalize: $_pass passed, $_fail failed"
[ "$_fail" -eq 0 ] || exit 1
