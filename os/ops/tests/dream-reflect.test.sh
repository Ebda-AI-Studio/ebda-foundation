#!/usr/bin/env bash
# dream-reflect: three memory lessons sharing a rare theme and no enforcement anywhere -> one unenforced-lesson finding appended to
# dream-findings.json; a second run is deduped by the ledger; an unreadable/empty corpus aborts (no phantom "0 lessons" finding).
# The scoped-memory scan is the Ebda business folder only (a lesson under a sibling business folder is never read).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1; OPS="$(pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
_pass=0; _fail=0
pass() { echo "PASS: $1"; _pass=$((_pass+1)); }
fail() { echo "FAIL: $1"; _fail=$((_fail+1)); }
BIZ="$T/proj/Ebda-AI-Studio"
mkdir -p "$T/home" "$T/state" "$T/mem" "$BIZ/internal-projects/ebda-store/.git" "$T/proj/Other-Biz/internal-projects/x/memory" "$BIZ/internal-projects/ebda-foundation"
for i in 1 2 3; do
  printf -- '---\nname: feedback-quokka-%s\ndescription: quokka zorblat rule %s\n---\nAlways check the quokka zorblat before shipping. quokka zorblat bit us again (%s).\n' "$i" "$i" "$i" > "$T/mem/feedback-quokka-$i.md"
  touch -t "20260$((i+1))010000" "$T/mem/feedback-quokka-$i.md"
done
# a lesson in a sibling business folder must not be read: it would make a 4th member of the cluster
printf -- '---\nname: feedback-quokka-other\n---\nquokka zorblat elsewhere\n' > "$T/proj/Other-Biz/internal-projects/x/memory/feedback-quokka-other.md"
E=(env HOME="$T/home" EBDA_OS_LOCAL_ENV="$T/none.env" OS_STATE_DIR="$T/state" OS_PROJECTS_DIR="$T/proj" OS_HOME="$BIZ/internal-projects/ebda-foundation" OS_MEMORY_DIR="$T/mem")

out="$("${E[@]}" bash "$OPS/dream-reflect.sh" 2>&1)"; rc=$?
[ "$rc" = 0 ] && pass "reflect exits 0" || { fail "rc=$rc"; echo "$out"; }
python3 -I -c "
import json,sys; d=json.load(open(sys.argv[1])); f=d['findings']
q=[x for x in f if x['class']=='reflect-unenforced-lesson' and 'quokka' in x['title']]
sys.exit(0 if q and q[0]['repo']=='__memory__' and 'feedback-quokka-other.md' not in q[0]['detail'] else 1)" "$T/state/dream-findings.json" && pass "unenforced recurring lesson found, sibling business folder not read" || { fail "no finding"; echo "$out" | tail -15; }
"${E[@]}" bash "$OPS/dream-reflect.sh" >/dev/null 2>&1
python3 -I -c "
import json,sys; f=[x for x in json.load(open(sys.argv[1]))['findings'] if 'quokka' in x['title']]
sys.exit(0 if len(f)==1 else 1)" "$T/state/dream-findings.json" && pass "second run deduped by the ledger" || fail "duplicate finding"

rm -rf "$T/state"; mkdir -p "$T/state"; rm -f "$T/mem/"*.md
"${E[@]}" bash "$OPS/dream-reflect.sh" >/dev/null 2>&1; rc=$?
{ [ "$rc" = 0 ] && [ ! -e "$T/state/dream-findings.json" ]; } && pass "empty corpus aborts without a finding" || fail "empty corpus wrote findings"

echo "── $_pass passed, $_fail failed ──"
[ "$_fail" -eq 0 ]
