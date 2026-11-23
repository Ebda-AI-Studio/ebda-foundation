#!/usr/bin/env bash
# dream-standard-drift: a sentinel memory lesson with a new slug is PLANNED as a draft PR against $OS_REPO_SLUG (dry-run), never the
# previous repo; lessons already in os/standard or without the sentinel are skipped; --reseed re-proposes legacy-ledger slugs once.
# Temp memory dir, temp foundation repo, stub gh. Never touches real state.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1; OPS="$(pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
_pass=0; _fail=0
pass() { echo "PASS: $1"; _pass=$((_pass+1)); }
fail() { echo "FAIL: $1"; _fail=$((_fail+1)); }
OLD="Force""AI-KW"   # the previous org, built so this file carries no predecessor literal

mkdir -p "$T/mem" "$T/fnd/os/standard" "$T/state" "$T/bin" "$T/home" "$T/proj/Ebda-AI-Studio/internal-projects/ebda-store/.git"
git -C "$T/fnd" init -q 2>/dev/null; : > "$T/fnd/os/standard/00-index.md"
printf -- '---\nname: feedback-new-lesson\ndescription: a new rule\n---\nbody\nindexed in global MEMORY.md\n' > "$T/mem/feedback-new-lesson.md"
printf -- '---\nname: feedback-no-sentinel\n---\nbody only\n' > "$T/mem/feedback-no-sentinel.md"
printf -- '---\nname: feedback-already-in-standard\n---\nindexed in global MEMORY.md\n' > "$T/mem/feedback-already-in-standard.md"
echo "sources: feedback-already-in-standard" > "$T/fnd/os/standard/rule.md"
printf -- '---\nname: reference-legacy-one\n---\nindexed in global MEMORY.md\n' > "$T/mem/reference-legacy-one.md"
touch -t 202001010000 "$T/mem/reference-legacy-one.md"   # old: outside the 7-day window
cat > "$T/bin/gh" <<'G'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"; case "$1 $2" in "issue create") echo "https://example.invalid/issues/1" ;; esac
G
chmod +x "$T/bin/gh"; : > "$T/gh.log"

run() { env HOME="$T/home" PATH="$T/bin:$PATH" GH_LOG="$T/gh.log" EBDA_OS_LOCAL_ENV="$T/none.env" OS_HOME="$T/fnd" OS_STATE_DIR="$T/state" \
  OS_MEMORY_DIR="$T/mem" OS_PROJECTS_DIR="$T/proj" bash "$OPS/dream-standard-drift.sh" "$@" 2>&1; }

# 1. dry-run: plans a draft PR against the configured repo for the new lesson only
out="$(DRY_RUN=1 run)"
grep -q "plan: draft PR on Ebda-AI-Studio/ebda-foundation for 'feedback-new-lesson'" <<<"$out" && pass "dry-run plans a draft PR against \$OS_REPO_SLUG" || { fail "no plan line"; echo "$out"; }
grep -q "feedback-no-sentinel" <<<"$out" && fail "no-sentinel file was a candidate" || pass "no-sentinel lesson ignored"
grep -q "feedback-already-in-standard" <<<"$out" && fail "lesson already in os/standard was a candidate" || pass "lesson already in os/standard ignored"
grep -q "$OLD" <<<"$out" && fail "output names the previous org" || pass "previous org never named"
[ ! -s "$T/gh.log" ] && pass "dry-run made no gh call" || fail "dry-run called gh"
[ ! -e "$T/state/standard-drift-proposed.json" ] && pass "dry-run wrote no ledger" || fail "dry-run wrote the ledger"

# 2. OS_REPO_SLUG override is honoured
out="$(OS_REPO_SLUG=acme/other-repo DRY_RUN=1 run)"
grep -q "draft PR on acme/other-repo" <<<"$out" && pass "slug comes from config, not a literal" || fail "slug override ignored"

# 3. real run without claude (issue fallback): gh targets the new repo, ledger records {at, repo}
out="$(DRIFT_NO_LLM=1 run)"
grep -q "issue create --repo Ebda-AI-Studio/ebda-foundation" "$T/gh.log" && pass "fallback issue opened on the new repo" || { fail "issue not on the new repo"; cat "$T/gh.log"; }
python3 -I -c "
import json,sys; d=json.load(open(sys.argv[1])); e=d['feedback-new-lesson']
sys.exit(0 if e.get('repo')=='Ebda-AI-Studio/ebda-foundation' else 1)" "$T/state/standard-drift-proposed.json" && pass "ledger entry carries the repo" || fail "ledger entry malformed"
out="$(DRY_RUN=1 run)"; grep -q "feedback-new-lesson" <<<"$out" && fail "proposed slug re-proposed" || pass "proposed slug not re-proposed"

# 4. legacy ledger (string = proposed to the previous repo): quiet by default, re-proposed once with --reseed
python3 -I -c "
import json,sys; p=sys.argv[1]; d=json.load(open(p)); d['reference-legacy-one']='2026-10-01T00:00:00'; json.dump(d,open(p,'w'))" "$T/state/standard-drift-proposed.json"
out="$(DRY_RUN=1 run)"; grep -q "reference-legacy-one" <<<"$out" && fail "legacy entry re-proposed without --reseed" || pass "legacy entry untouched without --reseed"
out="$(DRY_RUN=1 run --reseed)"; grep -q "plan: draft PR on Ebda-AI-Studio/ebda-foundation for 'reference-legacy-one'" <<<"$out" && pass "--reseed plans the legacy slug against the new repo (window ignored)" || { fail "--reseed did not plan it"; echo "$out"; }
: > "$T/gh.log"; DRIFT_NO_LLM=1 run --reseed >/dev/null
python3 -I -c "
import json,sys; e=json.load(open(sys.argv[1]))['reference-legacy-one']
sys.exit(0 if isinstance(e,dict) and e.get('repo')=='Ebda-AI-Studio/ebda-foundation' else 1)" "$T/state/standard-drift-proposed.json" && pass "reseed records the slug against the new repo" || fail "reseed did not record"
out="$(DRY_RUN=1 run --reseed)"; grep -q "reference-legacy-one" <<<"$out" && fail "slug re-proposed a second time" || pass "reseed proposes each slug once"

echo "── $_pass passed, $_fail failed ──"
[ "$_fail" -eq 0 ]
