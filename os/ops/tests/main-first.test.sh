#!/usr/bin/env bash
# main-first.sh — a fake `gh` on PATH serves fixtures and logs every POST; a throwaway STATE/LOG/HOME.
# Regression target (2026-11-14): main CI sat queued for hours behind pull_request runs on the 2 heavy runners.
set -uo pipefail
OPS="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; _pass=0; _fail=0
pass() { echo "PASS: $1"; _pass=$((_pass+1)); }
fail() { echo "FAIL: $1"; cat "$T/log" 2>/dev/null | tail -5; cat "$T/out" 2>/dev/null | tail -5; _fail=$((_fail+1)); }
trap 'rm -rf "$T"' EXIT
BIN="$T/bin"; FK="$T/fake"; mkdir -p "$BIN" "$FK" "$T/home"

cat > "$BIN/gh" <<'FAKE'
#!/usr/bin/env bash
FK="${FAKE_DIR:?}"
[ "${1:-}" = api ] || exit 1
shift; method=GET; path=""
while [ $# -gt 0 ]; do
  case "$1" in -X) method="$2"; shift ;; -f) shift ;; *) [ -z "$path" ] && path="$1" ;; esac
  shift
done
if [ "$method" = POST ]; then echo "$path" >> "$FK/posts.log"; if [ -f "$FK/postfail" ] && grep -q -F -f "$FK/postfail" <<<"$path"; then exit 1; fi; echo '{}'; exit 0; fi
echo "$path" >> "$FK/gets.log"
if [ -f "$FK/fail" ] && grep -q -F -f "$FK/fail" <<<"$path"; then echo "HTTP 504" >&2; exit 1; fi
f=""
case "$path" in
  */actions/runs\?branch=main*) f=main.json ;;
  */actions/runs\?status=queued*) f=prq.json ;;
  */actions/runs/*/jobs*) id="${path#*/actions/runs/}"; f="jobs_${id%%/*}.json" ;;
  */compare/*) s="${path#*/compare/}"; f="cmp_${s%%...*}.json" ;;
  */issues/*/labels) id="${path#*/issues/}"; f="labels_${id%%/*}.json" ;;
  */actions/runs/[0-9]*) id="${path#*/actions/runs/}"; f="run_${id}.json" ;;
  */pulls\?head=*) b="${path#*head=*:}"; b="${b%%&*}"; f="openpr_${b//\//_}.json" ;;
  */pulls/*/reviews*) id="${path#*/pulls/}"; f="reviews_${id%%/*}.json" ;;
  */pulls/*) id="${path#*/pulls/}"; f="pull_${id%%\?*}.json" ;;
esac
[ -f "$FK/$f" ] && cat "$FK/$f" || { [ "${f#labels_}" != "$f" ] && echo '[]' || exit 1; }
FAKE
chmod +x "$BIN/gh"

NOW=1794657600   # 2026-11-14T12:00:00Z
OLD="2026-11-14T11:30:00Z"   # 30 min before NOW
NEW="2026-11-14T11:58:00Z"   # 2 min before NOW

reset() { rm -rf "${FK:?}"/* "$T/state" "$T/log"; }
jq_() { python3 -c "import json,sys; json.dump($1, open('$FK/$2','w'))"; }
# main <id:sha:status:conclusion>... newest first
main() { local a="" s i sh st c; for s in "$@"; do IFS=: read -r i sh st c <<<"$s"; c="${c:+\"$c\"}"; c="${c:-null}"; a="$a{\"id\":$i,\"name\":\"CI\",\"head_sha\":\"$sh\",\"status\":\"$st\",\"conclusion\":$c,\"created_at\":\"2026-11-14T11:$((10+i%50)):00Z\"},"; done
  echo "{\"workflow_runs\":[${a%,}]}" > "$FK/main.json"; }
jobs() { echo "{\"jobs\":[{\"status\":\"queued\",\"created_at\":\"$2\",\"labels\":[\"self-hosted\",\"ebda-mac\"]}]}" > "$FK/jobs_$1.json"; }
prq() { local a="" s i br sha n; for s in "$@"; do IFS=: read -r i br sha n <<<"$s"; a="$a{\"id\":$i,\"status\":\"queued\",\"head_branch\":\"$br\",\"head_sha\":\"$sha\",\"pull_requests\":[{\"number\":$n}]},"; done
  echo "{\"workflow_runs\":[${a%,}]}" > "$FK/prq.json"; }
run() { FAKE_DIR="$FK" PATH="$BIN:$PATH" HOME="$T/home" MAIN_FIRST_REPOS="o/r" MAIN_FIRST_STATE="$T/state" MAIN_FIRST_LOG="$T/log" MAIN_FIRST_NOW="$NOW" MAIN_FIRST_VERIFY_WAIT=0 MAIN_FIRST_ALLOW_BRANCHES="${ALLOW:-}" bash "$OPS/main-first.sh" "$@" >"$T/out" 2>&1; }
posts() { cat "$FK/posts.log" 2>/dev/null; }
has() { posts | grep -q -F "$1"; }
# ledger runs are completed+cancelled unless a test says otherwise
canc() { for i in "$@"; do echo "{\"status\":\"completed\",\"conclusion\":\"cancelled\",\"run_attempt\":1}" > "$FK/run_$i.json"; done; }

# 1. main queued 30m + PR queued -> PR cancelled + one comment
reset; main 90:aaa:queued:; jobs 90 "$OLD"; prq 11:feat-x:p1:101; jobs 11 "$NEW"
run
has "actions/runs/11/cancel" && has "issues/101/comments" && ! has "actions/runs/90/cancel" && pass "queued PR run cancelled, comment left, main untouched" || fail "queued PR cancel ($(posts | tr '\n' ' '))"
run   # second tick: queued PR run is still listed (fake) -> comment must not repeat
[ "$(posts | grep -c issues/101/comments)" = 1 ] && pass "comment once per head" || fail "comment repeated"

# 2. in_progress PR run untouched (not in the queued listing; also a non-heavy queued run)
reset; main 90:aaa:queued:; jobs 90 "$OLD"; echo '{"workflow_runs":[]}' > "$FK/prq.json"
run; [ -z "$(posts)" ] && pass "in_progress PR run untouched (not listed as queued)" || fail "in_progress touched"
reset; main 90:aaa:queued:; jobs 90 "$OLD"; prq 12:feat-y:p2:102
echo '{"jobs":[{"status":"queued","created_at":"'"$NEW"'","labels":["ubuntu-latest"]}]}' > "$FK/jobs_12.json"
run; [ -z "$(posts)" ] && pass "queued PR run without the heavy label untouched" || fail "non-heavy cancelled"

# 3. superseded main cancelled, newest kept; non-ancestor kept
reset; main 93:ccc:queued: 92:bbb:in_progress: 91:zzz:queued:; jobs 93 "$OLD"
echo '{"status":"ahead"}' > "$FK/cmp_bbb.json"; echo '{"status":"diverged"}' > "$FK/cmp_zzz.json"; echo '{"workflow_runs":[]}' > "$FK/prq.json"
run
has "actions/runs/92/cancel" && ! has "actions/runs/93/cancel" && ! has "actions/runs/91/cancel" && pass "ancestor main run cancelled, newest + diverged kept" || fail "superseded ($(posts | tr '\n' ' '))"

# 4. API 504 -> no action (jobs read fails; and PR-jobs read fails after main starved)
reset; main 90:aaa:queued:; jobs 90 "$OLD"; prq 11:feat-x:p1:101; jobs 11 "$NEW"; echo "actions/runs/90/jobs" > "$FK/fail"
run; [ -z "$(posts)" ] && grep -q "skip tick" "$T/log" && pass "504 on main jobs -> no action" || fail "504 main jobs"
echo "actions/runs/11/jobs" > "$FK/fail"; rm -f "$T/state/o__r.cancelled.tsv"
run; [ -z "$(posts)" ] && pass "504 midway (partial data) -> no mutation at all" || fail "504 midway acted ($(posts | tr '\n' ' '))"
echo "actions/runs?branch=main" > "$FK/fail"; run; [ -z "$(posts)" ] && pass "504 on main runs -> no action" || fail "504 main runs"

# 5. allowlisted branch + fixes-main label untouched
reset; main 90:aaa:queued:; jobs 90 "$OLD"; prq 11:fix/main-red:p1:101 13:feat-z:p3:103; jobs 11 "$NEW"; jobs 13 "$NEW"
echo '[{"name":"fixes-main"}]' > "$FK/labels_103.json"
ALLOW="fix/main-red" run
[ -z "$(posts)" ] && pass "allowlisted branch and fixes-main label untouched" || fail "allowlist ($(posts | tr '\n' ' '))"

# 6. main not starved (job queued 2m) -> no action
reset; main 90:aaa:queued:; jobs 90 "$NEW"; prq 11:feat-x:p1:101; jobs 11 "$NEW"
run; [ -z "$(posts)" ] && pass "main not starved -> no action" || fail "acted on fresh queue"

# 7. dry run mutates nothing, writes no ledger
reset; main 90:aaa:queued:; jobs 90 "$OLD"; prq 11:feat-x:p1:101; jobs 11 "$NEW"
run --dry-run; [ -z "$(posts)" ] && grep -q "DRYRUN would cancel queued PR run 11" "$T/log" && [ ! -s "$T/state/o__r.cancelled.tsv" ] && pass "dry-run logs only" || fail "dry-run"

# 8. main green -> cancelled runs re-requested once, approved first, capped, closed/moved dropped
reset; main 95:ddd:completed:success
mkdir -p "$T/state"; printf '11\t101\tp1\t%s\n12\t102\tp2\t%s\n14\t104\tp4\t%s\n15\t105\tp5\t%s\n' "$NOW" "$NOW" "$NOW" "$NOW" > "$T/state/o__r.cancelled.tsv"
for n in 1 2 4; do echo "{\"state\":\"open\",\"head\":{\"sha\":\"p$n\"}}" > "$FK/pull_10$n.json"; done
canc 11 12 14 15
echo '{"state":"open","head":{"sha":"MOVED"}}' > "$FK/pull_105.json"
echo '[]' > "$FK/reviews_101.json"
echo '[{"user":{"login":"a"},"state":"APPROVED","submitted_at":"2026-11-14T10:00:00Z"}]' > "$FK/reviews_102.json"
echo '[{"user":{"login":"a"},"state":"APPROVED","submitted_at":"2026-11-14T09:00:00Z"}]' > "$FK/reviews_104.json"
run
[ "$(posts | tr '\n' ' ')" = "repos/o/r/actions/runs/14/rerun repos/o/r/actions/runs/12/rerun " ] && pass "re-run: oldest-approved first, capped at 2" || fail "rerun order ($(posts | tr '\n' ' '))"
run   # next tick: 14,12 gone from ledger; 15 dropped (head moved); 11 (unapproved) re-run once
[ "$(posts | tr '\n' ' ')" = "repos/o/r/actions/runs/14/rerun repos/o/r/actions/runs/12/rerun repos/o/r/actions/runs/11/rerun " ] && [ ! -s "$T/state/o__r.cancelled.tsv" ] && pass "each cancelled run re-requested exactly once; moved head dropped" || fail "rerun once ($(posts | tr '\n' ' '))"
run; [ "$(posts | wc -l | tr -d ' ')" = 3 ] && pass "idempotent: empty ledger -> nothing more" || fail "not idempotent"

# 10. cancel leaves the run queued -> force-cancel; cancel that works -> no force-cancel
reset; main 90:aaa:queued:; jobs 90 "$OLD"; prq 11:feat-x:p1:101 12:feat-y:p2:102; jobs 11 "$NEW"; jobs 12 "$NEW"
echo '{"status":"queued"}' > "$FK/run_11.json"; echo '{"status":"completed"}' > "$FK/run_12.json"
run
has "actions/runs/11/force-cancel" && ! has "actions/runs/12/force-cancel" && grep -q "still queued after cancel" "$T/log" && pass "queued after cancel -> force-cancel; completed -> none" || fail "force-cancel ($(posts | tr '\n' ' '))"

# 11. orphan run >24h with no open PR skipped; same age with an open PR is cancelled
reset; main 90:aaa:queued:; jobs 90 "$OLD"; jobs 11 "$NEW"; jobs 12 "$NEW"
echo '{"workflow_runs":[{"id":11,"status":"queued","head_branch":"gone","head_sha":"p1","pull_requests":[],"created_at":"2026-11-12T00:00:00Z"},{"id":12,"status":"queued","head_branch":"live","head_sha":"p2","pull_requests":[{"number":102}],"created_at":"2026-11-12T00:00:00Z"}]}' > "$FK/prq.json"
echo '[]' > "$FK/openpr_gone.json"; echo '[{"number":102}]' > "$FK/openpr_live.json"; echo '{"status":"completed"}' > "$FK/run_12.json"
run
has "actions/runs/12/cancel" && ! has "actions/runs/11/cancel" && grep -q "orphan run 11" "$T/log" && pass ">24h orphan skipped + logged; >24h with open PR still cancelled" || fail "orphan ($(posts | tr '\n' ' '))"

# 12. REAL captured GitHub responses (tests/fixtures/real-*.json, trimmed from `gh api` on ebda-store 2026-11-14):
# the parsers must read `workflow_runs` (a fixture with the old `runs` key finds no main run and acts on nothing).
FX="$(cd "$(dirname "$0")" && pwd)/fixtures"
reset; cp "$FX/real-main-runs.json" "$FK/main.json"; cp "$FX/real-pr-queued-runs.json" "$FK/prq.json"
python3 - "$FK" "$FX" <<'PY'
import json,sys
fk,fx=sys.argv[1:]
m=json.load(open(fx+"/real-main-runs.json"))["workflow_runs"]
ci=[r for r in m if r["name"]=="CI"][0]
q=json.load(open(fx+"/real-pr-queued-runs.json"))["workflow_runs"]
for rid,src in ((ci["id"],"real-jobs-main"),(q[0]["id"],"real-jobs-pr"),(q[1]["id"],"real-jobs-pr")):
    open(f"{fk}/jobs_{rid}.json","w").write(open(f"{fx}/{src}.json").read())
PY
echo "[]" > "$FK/openpr_chore_mac-light-runners.json"   # real >24h run whose branch has no open PR
CIID="$(python3 -c "import json;print([r for r in json.load(open('$FX/real-main-runs.json'))['workflow_runs'] if r['name']=='CI'][0]['id'])")"
PRID="$(python3 -c "import json;print(json.load(open('$FX/real-pr-queued-runs.json'))['workflow_runs'][0]['id'])")"
NOW=1794670000 run   # 2026-11-14T15:46:40Z, main jobs queued since 14:01 (~105 min)
has "actions/runs/$PRID/cancel" && ! has "actions/runs/$CIID/cancel" && pass "REAL fixtures: starved main found via workflow_runs, queued heavy PR run cancelled" || fail "real fixtures ($(posts | tr '\n' ' '))"
reset; python3 -c "
import json;d=json.load(open('$FX/real-main-runs.json'));json.dump({'total_count':d['total_count'],'runs':d['workflow_runs']},open('$FK/main.json','w'))"
run; grep -q "skip tick" "$T/log" && [ -z "$(posts)" ] && pass "a response keyed runs (the shape GitHub never returns) is rejected, no action" || fail "old key"

# 13. a repo whose main workflow is named lowercase `ci` (ebda-whatsapp) is matched too
reset; main 90:aaa:queued:; sed -i.bak 's/"name":"CI"/"name":"ci"/' "$FK/main.json"; rm -f "$FK/main.json.bak"
jobs 90 "$OLD"; prq 11:feat-x:p1:101; jobs 11 "$NEW"
run; has "actions/runs/11/cancel" && pass "lowercase 'ci' workflow name matched" || fail "lowercase ci ($(posts | tr '\n' ' '))"

# 9. main completed red -> nothing re-run
reset; main 95:ddd:completed:failure; mkdir -p "$T/state"; printf '11\t101\tp1\t%s\n' "$NOW" > "$T/state/o__r.cancelled.tsv"
run; [ -z "$(posts)" ] && [ -s "$T/state/o__r.cancelled.tsv" ] && pass "main red -> ledger kept, no re-run" || fail "red main"

# 14. BATCH-FIRST: main green + fresh drain batch file -> queued non-batch PR runs cancelled (batch, partially started, push kept)
bfile() { mkdir -p "$T/state"; printf '%s\n' "${@:2}" > "$T/state/drain-batch-o__r"; python3 -c "import os;os.utime('$T/state/drain-batch-o__r',($NOW-$1,$NOW-$1))"; }
pullf() { echo "{\"state\":\"open\",\"head\":{\"sha\":\"$2\",\"ref\":\"$3\"}}" > "$FK/pull_$1.json"; }
batch_world() {
  reset; main 95:ddd:completed:success
  pullf 101 p1 feat-batch
  echo '{"workflow_runs":[
   {"id":21,"status":"queued","event":"pull_request","head_branch":"feat-batch","head_sha":"p1","pull_requests":[{"number":101}]},
   {"id":22,"status":"queued","event":"pull_request","head_branch":"feat-other","head_sha":"p2","pull_requests":[{"number":102}]},
   {"id":23,"status":"queued","event":"pull_request","head_branch":"feat-part","head_sha":"p3","pull_requests":[{"number":103}]},
   {"id":24,"status":"queued","event":"push","head_branch":"feat-push","head_sha":"p4","pull_requests":[]}]}' > "$FK/prq.json"
  jobs 21 "$NEW"; jobs 22 "$NEW"; jobs 24 "$NEW"
  echo '{"jobs":[{"status":"in_progress","labels":["ebda-mac"]},{"status":"queued","labels":["ebda-mac"]}]}' > "$FK/jobs_23.json"
}
batch_world; bfile 60 101
run
has "actions/runs/22/cancel" && ! has "actions/runs/21/cancel" && ! has "actions/runs/23/cancel" && ! has "actions/runs/24/cancel" && grep -q "PR #102.*not in drain batch" "$T/log" && pass "batch fresh: non-batch queued run cancelled; batch, partially started and push runs kept" || fail "batch cancel ($(posts | tr '\n' ' '))"

batch_world; bfile $((20*60)) 101
run; [ -z "$(posts)" ] && grep -q "stale" "$T/log" && pass "stale batch file -> nothing cancelled (fail open)" || fail "stale batch ($(posts | tr '\n' ' '))"
batch_world
run; [ -z "$(posts)" ] && pass "missing batch file -> nothing cancelled" || fail "missing batch"
batch_world; bfile 60 101; run --dry-run
[ -z "$(posts)" ] && grep -q "DRYRUN would batch-first: cancel queued PR run 22" "$T/log" && pass "batch cancel honours dry-run" || fail "batch dry-run"
# main red -> batch never cancels
reset; main 95:ddd:completed:failure; bfile 60 101; run; [ -z "$(posts)" ] && pass "main not green -> no batch cancel" || fail "batch on red main"

# 15. re-run order: batch PRs first (even unapproved), non-batch held while batch fresh; stale -> old order
rr_world() {
  reset; main 95:ddd:completed:success; mkdir -p "$T/state"
  printf '12\t102\tp2\t%s\n14\t104\tp4\t%s\n11\t101\tp1\t%s\n' "$NOW" "$NOW" "$NOW" > "$T/state/o__r.cancelled.tsv"
  for n in 1 2 4; do pullf "10$n" "p$n" "b$n"; done; canc 11 12 14
  echo '[]' > "$FK/reviews_101.json"
  echo '[{"user":{"login":"a"},"state":"APPROVED","submitted_at":"2026-11-14T10:00:00Z"}]' > "$FK/reviews_102.json"
  echo '[{"user":{"login":"a"},"state":"APPROVED","submitted_at":"2026-11-14T09:00:00Z"}]' > "$FK/reviews_104.json"
  echo '{"workflow_runs":[]}' > "$FK/prq.json"
}
rr_world; bfile 60 101 102; run
[ "$(posts | tr '\n' ' ')" = "repos/o/r/actions/runs/12/rerun repos/o/r/actions/runs/11/rerun " ] && grep -q "PR #104 run 14 held" "$T/log" && pass "rerun: batch PRs first (approved before unapproved), non-batch held" || fail "batch rerun order ($(posts | tr '\n' ' '))"
rr_world; bfile $((20*60)) 101 102; run
[ "$(posts | tr '\n' ' ')" = "repos/o/r/actions/runs/14/rerun repos/o/r/actions/runs/12/rerun " ] && pass "stale batch -> old oldest-approval rerun order" || fail "stale rerun order ($(posts | tr '\n' ' '))"

# 16. state check before re-request (2026-11-15: a run another actor re-ran to SUCCESS was restarted ~10x, ~1h of CI wasted)
rs_world() { reset; main 95:ddd:completed:success; mkdir -p "$T/state"; printf '%s\t%s\tp%s\t%s\n' "$1" "$2" "${2#10}" "$NOW" > "$T/state/o__r.cancelled.tsv"; pullf "$2" "p${2#10}" "b"; echo '[]' > "$FK/reviews_$2.json"; }
rs_world 11 101; echo '{"status":"completed","conclusion":"success","run_attempt":3,"head_sha":"p1"}' > "$FK/run_11.json"
run; [ -z "$(posts)" ] && [ ! -s "$T/state/o__r.cancelled.tsv" ] && grep -q "run 11 dropped: already completed/success attempt 3" "$T/log" && pass "completed success run: not re-requested, dropped from ledger" || fail "success rerun ($(posts | tr '\n' ' '))"
rs_world 11 101; echo '{"status":"completed","conclusion":"failure","run_attempt":2,"head_sha":"p1"}' > "$FK/run_11.json"
run; [ -z "$(posts)" ] && [ ! -s "$T/state/o__r.cancelled.tsv" ] && pass "completed failure run: not re-requested, dropped" || fail "failure rerun"
for st in in_progress queued; do
  rs_world 11 101; echo "{\"status\":\"$st\",\"conclusion\":null,\"run_attempt\":4,\"head_sha\":\"p1\"}" > "$FK/run_11.json"
  run; [ -z "$(posts)" ] && [ ! -s "$T/state/o__r.cancelled.tsv" ] && grep -q "run 11 dropped: already $st attempt 4" "$T/log" && pass "$st run: not re-requested, dropped" || fail "$st rerun ($(posts | tr '\n' ' '))"
done
rs_world 11 101; canc 11
run; [ "$(posts | tr '\n' ' ')" = "repos/o/r/actions/runs/11/rerun " ] && [ ! -s "$T/state/o__r.cancelled.tsv" ] && pass "completed cancelled run re-requested exactly once" || fail "cancelled rerun ($(posts | tr '\n' ' '))"
run; [ "$(posts | wc -l | tr -d ' ')" = 1 ] && pass "no second request on the next tick" || fail "second request"
rs_world 11 101; echo '{"status":"completed","conclusion":"cancelled","run_attempt":1,"head_sha":"OTHER"}' > "$FK/run_11.json"
run; [ -z "$(posts)" ] && [ ! -s "$T/state/o__r.cancelled.tsv" ] && pass "cancelled run on a different head: dropped, not re-requested" || fail "head mismatch"
rs_world 11 101; canc 11; echo "actions/runs/11/rerun" > "$FK/postfail"
run; [ "$(posts | wc -l | tr -d ' ')" = 1 ] && [ ! -s "$T/state/o__r.cancelled.tsv" ] && [ "$(grep -c 'FAILED re-request cancelled run 11' "$T/log")" = 1 ] && pass "failing re-request: logged once, dropped, never retried" || fail "failing rerun ($(posts | tr '\n' ' '))"
run; [ "$(posts | wc -l | tr -d ' ')" = 1 ] && pass "dropped failing id not retried next tick" || fail "retried"
rs_world 11 101; canc 11; printf '11\t101\tp1\t%s\n' "$NOW" >> "$T/state/o__r.cancelled.tsv"
run; [ "$(posts | wc -l | tr -d ' ')" = 1 ] && [ ! -s "$T/state/o__r.cancelled.tsv" ] && pass "duplicate ledger id requested once per tick" || fail "duplicate ($(posts | tr '\n' ' '))"
rs_world 11 101; run; [ -z "$(posts)" ] && [ -s "$T/state/o__r.cancelled.tsv" ] && pass "run read fails -> kept in ledger, no request" || fail "run read failure"

echo "$_pass passed, $_fail failed"; [ "$_fail" = 0 ]
