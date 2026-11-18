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
if [ "$method" = POST ]; then echo "$path" >> "$FK/posts.log"; if [ -f "$FK/postfail" ] && grep -q -F -f "$FK/postfail" <<<"$path"; then exit 1; fi
  # a rerun that takes: the run reads back queued on attempt 2 (unless the run is listed in $FK/norerun, the re-run that silently does not take)
  case "$path" in */actions/runs/*/rerun) rid="${path#*/actions/runs/}"; rid="${rid%%/*}"; { [ -f "$FK/norerun" ] && grep -qx "$rid" "$FK/norerun"; } || echo '{"status":"queued","conclusion":null,"run_attempt":2,"head_sha":"'"$(sed -n 's/.*"head_sha": *"\([^"]*\)".*/\1/p' "$FK/run_$rid.json" 2>/dev/null | head -1)"'"}' > "$FK/run_$rid.json" ;; esac
  echo '{}'; exit 0; fi
echo "$path" >> "$FK/gets.log"
if [ -f "$FK/fail" ] && grep -q -F -f "$FK/fail" <<<"$path"; then echo "HTTP 504" >&2; exit 1; fi
f=""
case "$path" in
  */actions/runs\?event=merge_group*) if [ -f "$FK/mg.json" ]; then cat "$FK/mg.json"; else echo '{"workflow_runs":[]}'; fi; exit 0 ;;
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
# `<fixture>.seq` = one fixture file name per line, served in call order (the last one repeats): state that changes while a lease loop runs
if [ -n "$f" ] && [ -f "$FK/$f.seq" ]; then
  n=$(cat "$FK/$f.n" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$FK/$f.n"
  g="$(sed -n "${n}p" "$FK/$f.seq")"; [ -n "$g" ] || g="$(tail -1 "$FK/$f.seq")"; f="$g"
fi
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
run() { env FAKE_DIR="$FK" PATH="$BIN:$PATH" HOME="$T/home" MAIN_FIRST_REPOS="o/r" MAIN_FIRST_STATE="$T/state" MAIN_FIRST_LOG="$T/log" MAIN_FIRST_NOW="$NOW" MAIN_FIRST_VERIFY_WAIT=0 MAIN_FIRST_ALLOW_BRANCHES="${ALLOW:-}" ${LV:-MAIN_FIRST_LEASE=0} bash "$OPS/main-first.sh" "$@" >"$T/out" 2>&1; }
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
# HELD-RERUN-1: with a RECENT queued run in the repo the non-batch run is HELD (the batch needs the runners); batch PRs first (approved before unapproved)
rr_world; echo "{\"workflow_runs\":[{\"id\":900,\"status\":\"queued\",\"event\":\"pull_request\",\"created_at\":\"$NEW\",\"head_branch\":\"b1\",\"head_sha\":\"p1\",\"pull_requests\":[{\"number\":101}]}]}" > "$FK/prq.json"; bfile 60 101 102; run
[ "$(posts | tr '\n' ' ')" = "repos/o/r/actions/runs/12/rerun repos/o/r/actions/runs/11/rerun " ] && grep -q "PR #104 run 14 held" "$T/log" && pass "rerun: batch PRs first (approved before unapproved), non-batch held while a run is queued" || fail "batch rerun order ($(posts | tr '\n' ' '))"
# HELD-RERUN-1, the measured case (#811, 2026-11-17): fresh batch file, main green, NOTHING queued: the held run starts (it used to sit held for hours with idle runners)
rr_world; bfile 60 101 102; MAIN_FIRST_RERUN_CAP=5 run
[ "$(posts | tr '\n' ' ')" = "repos/o/r/actions/runs/12/rerun repos/o/r/actions/runs/11/rerun repos/o/r/actions/runs/14/rerun " ] && ! grep -q "run 14 held" "$T/log" && pass "HELD-RERUN-1: batch fresh but the repo is idle (nothing queued): the non-batch run is released after the batch PRs" || fail "idle release ($(posts | tr '\n' ' '))"
# a queued GHOST (older than the recent window, e.g. the Nov-11 runs that can never be cancelled) does not count as busy
rr_world; echo '{"workflow_runs":[{"id":901,"status":"queued","event":"pull_request","created_at":"2026-11-10T08:00:00Z","head_branch":"old","head_sha":"x","pull_requests":[{"number":5}]}]}' > "$FK/prq.json"; bfile 60 101 102; MAIN_FIRST_RERUN_CAP=5 run
has "actions/runs/14/rerun" && pass "HELD-RERUN-1: a days-old queued ghost run does not keep the repo 'busy'" || fail "ghost counted as busy ($(posts | tr '\n' ' '))"
# an API error reading the queue is 'not idle': the hold stays (fail safe)
rr_world; echo "actions/runs?status=queued" > "$FK/fail"; bfile 60 101 102; MAIN_FIRST_RERUN_CAP=5 run
! has "actions/runs/14/rerun" && grep -q "PR #104 run 14 held" "$T/log" && pass "HELD-RERUN-1: unreadable queue -> hold stays (fail safe)" || fail "api error released the hold ($(posts | tr '\n' ' '))"
rm -f "$FK/fail"
# HELD-RERUN-1b: the LAUNCH LIST (drain priority, file launch-list-o__r). The idle release runs launch PRs first and keeps non-launch runs held while a launch PR is pending.
lfile() { mkdir -p "$T/state"; printf '%s\n' "$@" > "$T/state/launch-list-o__r"; }
# idle + launch PR 104 held + non-launch 101/102 held: ONLY the launch PR is re-run first, the others stay held ("a launch-list PR is still pending")
rr_world; lfile 104; bfile 60 998 999; MAIN_FIRST_RERUN_CAP=5 run
[ "$(posts | tr '\n' ' ')" = "repos/o/r/actions/runs/14/rerun " ] && grep -q "held: a launch-list PR is still pending" "$T/log" && pass "HELD-RERUN-1b: idle + a launch PR held -> the launch PR is re-run first, non-launch runs stay held" || fail "launch first ($(posts | tr '\n' ' '))"
# idle + NO launch PR pending in the ledger: non-launch runs are released (approved first, old order)
rr_world; lfile 555 556; bfile 60 998 999; MAIN_FIRST_RERUN_CAP=5 run
[ "$(posts | tr '\n' ' ')" = "repos/o/r/actions/runs/14/rerun repos/o/r/actions/runs/12/rerun repos/o/r/actions/runs/11/rerun " ] && pass "HELD-RERUN-1b: idle and no launch-list PR pending -> non-launch runs are released (approved first)" || fail "non-launch release ($(posts | tr '\n' ' '))"
# launch order is the launch LIST order, not approval order
rr_world; lfile 102 101 104; bfile 60 998 999; MAIN_FIRST_RERUN_CAP=5 run
[ "$(posts | tr '\n' ' ')" = "repos/o/r/actions/runs/12/rerun repos/o/r/actions/runs/11/rerun repos/o/r/actions/runs/14/rerun " ] && pass "HELD-RERUN-1b: launch PRs re-run in launch-list order" || fail "launch order ($(posts | tr '\n' ' '))"
# unreadable / empty / missing list -> the old order, never a hold (idle release as in HELD-RERUN-1)
rr_world; mkdir -p "$T/state"; : > "$T/state/launch-list-o__r"; bfile 60 998 999; MAIN_FIRST_RERUN_CAP=5 run
[ "$(posts | tr '\n' ' ')" = "repos/o/r/actions/runs/14/rerun repos/o/r/actions/runs/12/rerun repos/o/r/actions/runs/11/rerun " ] && ! grep -q "launch-list PR is still pending" "$T/log" && pass "HELD-RERUN-1b: an empty launch list -> old order, no hold" || fail "empty list ($(posts | tr '\n' ' '))"
rr_world; printf 'garbage\nnot a pr\n' > "$T/state/launch-list-o__r"; bfile 60 998 999; MAIN_FIRST_RERUN_CAP=5 run
[ "$(posts | tr '\n' ' ')" = "repos/o/r/actions/runs/14/rerun repos/o/r/actions/runs/12/rerun repos/o/r/actions/runs/11/rerun " ] && pass "HELD-RERUN-1b: an unparseable launch list -> old order, no hold" || fail "garbage list ($(posts | tr '\n' ' '))"
rr_world; bfile 60 998 999; MAIN_FIRST_RERUN_CAP=5 run
[ "$(posts | tr '\n' ' ')" = "repos/o/r/actions/runs/14/rerun repos/o/r/actions/runs/12/rerun repos/o/r/actions/runs/11/rerun " ] && pass "HELD-RERUN-1b: no launch list file -> old order, no hold" || fail "missing list ($(posts | tr '\n' ' '))"
# RERUN_CAP per tick stays
rr_world; lfile 104 102 101; bfile 60 998 999; MAIN_FIRST_RERUN_CAP=2 run
[ "$(posts | tr '\n' ' ')" = "repos/o/r/actions/runs/14/rerun repos/o/r/actions/runs/12/rerun " ] && pass "HELD-RERUN-1b: the per-tick re-run cap still applies to the launch order" || fail "cap ($(posts | tr '\n' ' '))"
rr_world; bfile $((20*60)) 101 102; run
[ "$(posts | tr '\n' ' ')" = "repos/o/r/actions/runs/14/rerun repos/o/r/actions/runs/12/rerun " ] && pass "stale batch -> old oldest-approval rerun order" || fail "stale rerun order ($(posts | tr '\n' ' '))"

# 15b. MAIN-FIRST-MQ-1: no re-request of a NON-launch PR run while the merge queue has a run queued / in progress; a non-launch run is re-requested ONCE per head
mqrun() { echo "{\"workflow_runs\":[{\"id\":70,\"name\":\"CI\",\"event\":\"merge_group\",\"head_branch\":\"gh-readonly-queue/main/pr-9-abc\",\"head_sha\":\"mmm\",\"status\":\"$1\",\"conclusion\":null,\"created_at\":\"2026-11-14T11:30:00Z\"}]}" > "$FK/mg.json"; }
# queue busy + launch PR 104: ONLY the launch PR is re-requested; the non-launch runs 11 and 12 stay held (and stay in the ledger)
rr_world; lfile 104; mqrun queued; MAIN_FIRST_RERUN_CAP=5 run
[ "$(posts | tr '\n' ' ')" = "repos/o/r/actions/runs/14/rerun " ] && grep -q "PR #101 run 11 held: the merge queue has a run queued or in progress" "$T/log" && grep -q "^11	101	p1	" "$T/state/o__r.cancelled.tsv" && pass "merge-queue: busy -> only the launch-list PR run is re-requested, non-launch runs held and kept in the ledger" || fail "mq busy ($(posts | tr '\n' ' '))"
# queue busy and NO launch PR: nothing is re-requested at all
rr_world; lfile 555; mqrun in_progress; MAIN_FIRST_RERUN_CAP=5 run
[ -z "$(posts)" ] && [ "$(wc -l < "$T/state/o__r.cancelled.tsv" | tr -d ' ')" = 3 ] && pass "merge-queue: busy, no launch PR -> no re-request, all 3 rows kept" || fail "mq busy no launch ($(posts | tr '\n' ' '))"
# queue idle (the only merge_group run is completed): the old order, all re-requested
rr_world; lfile 555; echo '{"workflow_runs":[{"id":70,"name":"CI","event":"merge_group","head_branch":"gh-readonly-queue/main/pr-9-abc","status":"completed","conclusion":"success"}]}' > "$FK/mg.json"; MAIN_FIRST_RERUN_CAP=5 run
[ "$(posts | tr '\n' ' ')" = "repos/o/r/actions/runs/14/rerun repos/o/r/actions/runs/12/rerun repos/o/r/actions/runs/11/rerun " ] && pass "merge-queue: idle (a completed queue run) -> the old order, nothing held" || fail "mq idle ($(posts | tr '\n' ' '))"
# a queued run that is NOT on a queue branch does not count as a queue run
rr_world; lfile 555; echo '{"workflow_runs":[{"id":71,"name":"CI","event":"merge_group","head_branch":"feat-x","status":"queued"}]}' > "$FK/mg.json"; MAIN_FIRST_RERUN_CAP=5 run
[ "$(posts | wc -l | tr -d ' ')" = 3 ] && pass "merge-queue: a queued run on a non-queue branch is not a queue run" || fail "mq branch filter ($(posts | tr '\n' ' '))"
# the merge-queue runs unreadable: fail closed for non-launch runs
rr_world; lfile 104; echo "event=merge_group" > "$FK/fail"; MAIN_FIRST_RERUN_CAP=5 run
[ "$(posts | tr '\n' ' ')" = "repos/o/r/actions/runs/14/rerun " ] && grep -q "merge-queue runs unreadable" "$T/log" && pass "merge-queue: unreadable -> non-launch re-requests held (fail closed), launch PR still re-requested" || fail "mq unreadable ($(posts | tr '\n' ' '))"
# ONCE PER HEAD: a non-launch run re-requested once is NOT re-requested again for the same head (the cancel/revive loop); a launch run is
rr_world; lfile 104; MAIN_FIRST_RERUN_CAP=5 run
[ "$(posts | wc -l | tr -d ' ')" = 3 ] && grep -qx "11 p1" "$T/state/o__r.rerun.once" && ! grep -q "^14 " "$T/state/o__r.rerun.once" && pass "once-per-head: a non-launch re-request is recorded (run 11, head p1); the launch run is not" || fail "once mark ($(cat "$T/state/o__r.rerun.once" 2>/dev/null | tr '\n' ' '))"
rm -f "$FK/posts.log"; printf '11\t101\tp1\t%s\n14\t104\tp4\t%s\n' "$NOW" "$NOW" > "$T/state/o__r.cancelled.tsv"; canc 11 14   # both cancelled AGAIN on the same heads
MAIN_FIRST_RERUN_CAP=5 run
[ "$(posts | tr '\n' ' ')" = "repos/o/r/actions/runs/14/rerun " ] && grep -q "run 11 not re-requested again: already re-requested once for head p1" "$T/log" && ! grep -q "^11	" "$T/state/o__r.cancelled.tsv" && pass "once-per-head: the same non-launch run cancelled again is dropped, not revived; the launch run is re-requested again" || fail "once guard ($(posts | tr '\n' ' '))"
# a NEW head is a new run id and a new key: re-requested once more
rm -f "$FK/posts.log"; printf '15\t101\tp9\t%s\n' "$NOW" > "$T/state/o__r.cancelled.tsv"; pullf 101 p9 b1; echo '{"status":"completed","conclusion":"cancelled","run_attempt":1,"head_sha":"p9"}' > "$FK/run_15.json"
MAIN_FIRST_RERUN_CAP=5 run
[ "$(posts | tr '\n' ' ')" = "repos/o/r/actions/runs/15/rerun " ] && pass "once-per-head: a new head (new run) is re-requested once more" || fail "new head ($(posts | tr '\n' ' '))"

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

# ---- 9. MAIN LEASE (MAIN-LEASE-1): a refill during the lease is cancelled on arrival, protected runs are untouched,
#         the lease is released and the frozen runs re-run when main's last job starts, never held without a queued main job
LV="MAIN_FIRST_LEASE=1 MAIN_FIRST_LEASE_TICK=0 MAIN_FIRST_LEASE_BUDGET=6 MAIN_FIRST_LEASE_MIN_QUEUED_S=0 MAIN_FIRST_MIN=9999"
qjob() { echo "{\"jobs\":[{\"status\":\"queued\",\"created_at\":\"$2\",\"labels\":[\"self-hosted\",\"ebda-mac\"]}]}" > "$FK/$1"; }
sjob() { echo '{"jobs":[{"status":"in_progress","created_at":"'"$2"'","labels":["self-hosted","ebda-mac"]}]}' > "$FK/$1"; }
runs_json() { local a="" s i br sha n; for s in "$@"; do IFS=: read -r i br sha n <<<"$s"; a="$a{\"id\":$i,\"status\":\"queued\",\"head_branch\":\"$br\",\"head_sha\":\"$sha\",\"pull_requests\":[{\"number\":$n}]},"; done; echo "{\"workflow_runs\":[${a%,}]}"; }
reset; main 90:aaa:queued:
# main jobs read, in call order: 1 = the normal pass, 2 = lease step 1, 3 = step 2 (refill arrives), 4 = step 3 (last job started)
qjob jobs_90_q.json "$OLD"; sjob jobs_90_s.json "$OLD"; printf 'jobs_90_q.json\njobs_90_q.json\njobs_90_q.json\njobs_90_s.json\n' > "$FK/jobs_90.json.seq"; : > "$FK/jobs_90.json"
echo '{"workflow_runs":[]}' > "$FK/prq_0.json"
# arrivals: 21 plain (cancelled), 22 batch PR (protected), 23 fixes-main label (protected), 24 allow-listed branch (protected), 25 already started (left alone)
runs_json 21:feat-a:pa:201 22:feat-b:pb:202 23:feat-c:pc:203 24:fix/main-red:pd:204 25:feat-e:pe:205 > "$FK/prq_1.json"
printf 'prq_0.json\nprq_1.json\n' > "$FK/prq.json.seq"; : > "$FK/prq.json"
for n in 21 22 23 24; do qjob "jobs_$n.json" "$NEW"; done
echo '{"jobs":[{"status":"queued","created_at":"'"$NEW"'","labels":["self-hosted","ebda-mac"]},{"status":"in_progress","created_at":"'"$NEW"'","labels":["self-hosted","ebda-mac"]}]}' > "$FK/jobs_25.json"
echo '[{"name":"fixes-main"}]' > "$FK/labels_203.json"
mkdir -p "$T/state"; echo 202 > "$T/state/drain-batch-o__r"
# the cancelled run is completed+cancelled afterwards, its PR open on the same head, approved
echo '{"status":"completed","conclusion":"cancelled","run_attempt":1,"head_sha":"pa"}' > "$FK/run_21.json"
echo '{"state":"open","head":{"sha":"pa"}}' > "$FK/pull_201.json"; echo '[]' > "$FK/reviews_201.json"
ALLOW="fix/main-red" run
cancels="$(posts | grep -c '/cancel$')"
has "actions/runs/21/cancel" && [ "$cancels" = 1 ] && pass "lease: the refill (run 21) is cancelled on arrival; batch PR, fixes-main PR, allow-listed branch and a started run are untouched" || fail "lease cancel set ($(posts | tr '\n' ' '))"
grep -q "lease ACQUIRED" "$T/log" && pass "lease: acquired when main has a queued job" || fail "no lease acquired"
grep -q "lease: cancel PR run 21 on arrival .*pool=ebda-mac) so main run" "$T/log" && pass "lease: the cancel log line names the HEAVY pool (pool=ebda-mac)" || fail "heavy cancel line lacks pool=ebda-mac: $(grep 'cancel PR run 21' "$T/log" | head -1)"
[ ! -e "$T/state/o__r.lease" ] && [ ! -s "$T/state/o__r.lease.tsv" ] && grep -q "lease released" "$T/log" && pass "lease: lease file and lease ledger cleared on release" || fail "lease state left behind"
# a fresh drain batch is listed: the non-batch run is HELD (re-running it would only be re-cancelled), so it moves to the normal ledger, not re-run now
! has "actions/runs/21/rerun" && grep -q "^21	201	pa	" "$T/state/o__r.cancelled.tsv" && pass "lease: with a fresh drain batch the cancelled non-batch run is held and handed to the normal ledger" || fail "held run not handed over ($(posts | tr '\n' ' '))"

# no batch file: the lease release re-runs the cancelled run at once (after its cancel), nothing else is touched
reset; main 90:aaa:queued:
qjob jobs_90_q.json "$OLD"; sjob jobs_90_s.json "$OLD"; printf 'jobs_90_q.json\njobs_90_q.json\njobs_90_q.json\njobs_90_s.json\n' > "$FK/jobs_90.json.seq"; : > "$FK/jobs_90.json"
echo '{"workflow_runs":[]}' > "$FK/prq_0.json"; runs_json 21:feat-a:pa:201 23:feat-c:pc:203 > "$FK/prq_1.json"
printf 'prq_0.json\nprq_1.json\n' > "$FK/prq.json.seq"; : > "$FK/prq.json"
qjob jobs_21.json "$NEW"; qjob jobs_23.json "$NEW"; echo '[{"name":"fixes-main"}]' > "$FK/labels_203.json"
echo '{"status":"completed","conclusion":"cancelled","run_attempt":1,"head_sha":"pa"}' > "$FK/run_21.json"
echo '{"state":"open","head":{"sha":"pa"}}' > "$FK/pull_201.json"; echo '[]' > "$FK/reviews_201.json"
run
has "actions/runs/21/rerun" && ! has "actions/runs/23/" && [ "$(posts | grep -n 'runs/21/cancel' | cut -d: -f1)" -lt "$(posts | grep -n 'runs/21/rerun' | cut -d: -f1)" ] && grep -q "lease released" "$T/log" && pass "lease: released when main's last job starts, the cancelled run is re-run at once (after its cancel), the fixes-main run never touched" || fail "no release re-run ($(posts | tr '\n' ' '))"

# MAIN-FIRST-MQ-1 on the LEASE path: the same release, but the merge queue has a run in progress: the non-launch run is NOT re-requested, it is handed to the normal ledger
reset; main 90:aaa:queued:
qjob jobs_90_q.json "$OLD"; sjob jobs_90_s.json "$OLD"; printf 'jobs_90_q.json\njobs_90_q.json\njobs_90_q.json\njobs_90_s.json\n' > "$FK/jobs_90.json.seq"; : > "$FK/jobs_90.json"
echo '{"workflow_runs":[]}' > "$FK/prq_0.json"; runs_json 21:feat-a:pa:201 > "$FK/prq_1.json"
printf 'prq_0.json\nprq_1.json\n' > "$FK/prq.json.seq"; : > "$FK/prq.json"
qjob jobs_21.json "$NEW"
echo '{"status":"completed","conclusion":"cancelled","run_attempt":1,"head_sha":"pa"}' > "$FK/run_21.json"
echo '{"state":"open","head":{"sha":"pa"}}' > "$FK/pull_201.json"; echo '[]' > "$FK/reviews_201.json"
mqrun in_progress
run
has "actions/runs/21/cancel" && ! has "actions/runs/21/rerun" && grep -q "^21	201	pa	" "$T/state/o__r.cancelled.tsv" && grep -q "lease: PR #201 run 21 held: the merge queue has a run queued or in progress" "$T/log" && pass "merge-queue (lease path): a non-launch run is not re-requested while the queue is busy, it is handed to the normal ledger" || fail "lease mq hold ($(posts | tr '\n' ' '))"
rm -f "$FK/mg.json"

# never held while main has no queued job (all its jobs already running): nothing cancelled, no lease file
reset; main 90:aaa:in_progress:; sjob jobs_90.json "$OLD"; runs_json 21:feat-a:pa:201 > "$FK/prq.json"; qjob jobs_21.json "$NEW"
run; [ -z "$(posts)" ] && [ ! -e "$T/state/o__r.lease" ] && ! grep -q "lease ACQUIRED" "$T/log" && pass "lease: never held while main has no queued job" || fail "lease held with no queued main job ($(posts | tr '\n' ' '))"
# a queued main job younger than the grace does not take a lease (a job that starts at once costs nothing)
reset; main 90:aaa:queued:; qjob jobs_90.json "$NEW"; runs_json 21:feat-a:pa:201 > "$FK/prq.json"; qjob jobs_21.json "$NEW"
LV="MAIN_FIRST_LEASE=1 MAIN_FIRST_LEASE_TICK=0 MAIN_FIRST_LEASE_BUDGET=3 MAIN_FIRST_LEASE_MIN_QUEUED_S=600 MAIN_FIRST_MIN=9999" run
[ -z "$(posts)" ] && pass "lease: a main job queued under the grace (600 s) takes no lease" || fail "lease taken inside the grace"
# off switch, dry run, API failure
LV="MAIN_FIRST_LEASE=0 MAIN_FIRST_MIN=9999"; reset; main 90:aaa:queued:; qjob jobs_90.json "$OLD"; runs_json 21:feat-a:pa:201 > "$FK/prq.json"; qjob jobs_21.json "$NEW"
run; [ -z "$(posts)" ] && pass "lease: MAIN_FIRST_LEASE=0 turns it off" || fail "lease ran while off"
LV="MAIN_FIRST_LEASE=1 MAIN_FIRST_LEASE_TICK=0 MAIN_FIRST_LEASE_BUDGET=6 MAIN_FIRST_LEASE_MIN_QUEUED_S=0 MAIN_FIRST_MIN=9999"; reset; main 90:aaa:queued:; qjob jobs_90.json "$OLD"; runs_json 21:feat-a:pa:201 > "$FK/prq.json"; qjob jobs_21.json "$NEW"
run --dry-run; [ -z "$(posts)" ] && [ ! -e "$T/state/o__r.lease" ] && grep -q "DRYRUN would lease: cancel PR run 21" "$T/log" && pass "lease: dry-run logs the cancel and mutates nothing (one step, no wait)" || fail "lease dry-run ($(posts | tr '\n' ' '))"
reset; main 90:aaa:queued:; qjob jobs_90.json "$OLD"; runs_json 21:feat-a:pa:201 > "$FK/prq.json"; qjob jobs_21.json "$NEW"; echo "actions/runs/21/jobs" > "$FK/fail"
run; [ -z "$(posts)" ] && grep -q "lease: API failure reading jobs of 21" "$T/log" && pass "lease: an API failure reading a PR run's jobs skips the step, cancels nothing" || fail "lease acted on partial data ($(posts | tr '\n' ' '))"
unset LV

# ---- review fixes for #105 (2026-11-17)
LV="MAIN_FIRST_LEASE=1 MAIN_FIRST_LEASE_TICK=0 MAIN_FIRST_LEASE_BUDGET=12 MAIN_FIRST_LEASE_MIN_QUEUED_S=0 MAIN_FIRST_MIN=9999"
qjobl() { echo "{\"jobs\":[{\"status\":\"queued\",\"created_at\":\"$2\",\"labels\":$3}]}" > "$FK/$1"; }
cnt() { posts | grep -c "$1"; }
cancelled21() { echo '{"status":"completed","conclusion":"cancelled","run_attempt":1,"head_sha":"pa"}' > "$FK/run_21.json"; echo '{"state":"open","head":{"sha":"pa"}}' > "$FK/pull_201.json"; echo '[]' > "$FK/reviews_201.json"; }
echo '{"workflow_runs":[]}' > "$FK/prq_0.json"

# (A) main queues in WAVES: queued, nothing queued for ONE step, queued again: the lease is kept (no release, no re-run, no second cancel); it is
#     released only after 2 empty steps in a row, and the run is re-run ONCE
reset; main 90:aaa:in_progress:
qjob jobs_90_q.json "$OLD"; sjob jobs_90_s.json "$OLD"
# reads of main's jobs: 1 normal pass, 2 step1 queued, 3 step2 empty, 4 step3 queued (next wave), 5 step4 empty, 6 step5 empty -> released
printf 'jobs_90_q.json\njobs_90_q.json\njobs_90_s.json\njobs_90_q.json\njobs_90_s.json\njobs_90_s.json\n' > "$FK/jobs_90.json.seq"; : > "$FK/jobs_90.json"
runs_json 21:feat-a:pa:201 > "$FK/prq_1.json"; printf 'prq_1.json\n' > "$FK/prq.json.seq"; : > "$FK/prq.json"
qjob jobs_21.json "$NEW"; cancelled21
run
[ "$(cnt 'runs/21/cancel')" = 1 ] && [ "$(cnt 'runs/21/rerun')" = 1 ] && grep -q "no queued job (1/2)" "$T/log" && grep -q "lease released" "$T/log" && pass "lease hysteresis: a wave with no queued job for ONE step keeps the lease; released after 2 empty steps; one cancel, one re-run, no churn" || fail "hysteresis ($(posts | tr '\n' ' '))"
# (B) main's run COMPLETES: released at once (no 2-step wait)
reset; main 90:aaa:completed:success; echo '{"jobs":[]}' > "$FK/jobs_90.json"; mkdir -p "$T/state"; printf '21\t201\tpa\t%s\n' "$NOW" > "$T/state/o__r.lease.tsv"; printf '90\t%s\n' "$NOW" > "$T/state/o__r.lease"; echo '{"workflow_runs":[]}' > "$FK/prq.json"; cancelled21
run; has "actions/runs/21/rerun" && [ ! -e "$T/state/o__r.lease" ] && pass "lease: main completed -> released immediately and the cancelled run re-run" || fail "no immediate release ($(posts | tr '\n' ' '))"
# (C) a run still CANCELLING at release is kept and re-run on a later step (not dropped)
reset; main 90:aaa:completed:success; echo '{"jobs":[]}' > "$FK/jobs_90.json"; mkdir -p "$T/state"; printf '21\t201\tpa\t%s\n' "$NOW" > "$T/state/o__r.lease.tsv"; printf '90\t%s\n' "$NOW" > "$T/state/o__r.lease"; echo '{"workflow_runs":[]}' > "$FK/prq.json"
echo '{"status":"in_progress","conclusion":null,"run_attempt":1,"head_sha":"pa"}' > "$FK/run_21_a.json"; cancelled21; printf 'run_21_a.json\nrun_21.json\n' > "$FK/run_21.json.seq"
echo '{"state":"open","head":{"sha":"pa"}}' > "$FK/pull_201.json"; echo '[]' > "$FK/reviews_201.json"
run
[ "$(cnt 'runs/21/rerun')" = 1 ] && grep -q "still in_progress (cancelling)" "$T/log" && [ ! -s "$T/state/o__r.lease.tsv" ] && pass "lease: a run still cancelling at release is kept, then re-run on the next step (not dropped)" || fail "mid-cancel run dropped ($(posts | tr '\n' ' '); $(grep -c cancelling "$T/log"))"
# (D) a re-run that does not take is retried, then reported (LEASE-RERUN-FAILED) after 5 steps and dropped
reset; main 90:aaa:completed:success; echo '{"jobs":[]}' > "$FK/jobs_90.json"; mkdir -p "$T/state"; printf '21\t201\tpa\t%s\n' "$NOW" > "$T/state/o__r.lease.tsv"; echo '{"workflow_runs":[]}' > "$FK/prq.json"; cancelled21; echo 21 > "$FK/norerun"
run
grep -q "LEASE-RERUN-FAILED run 21" "$T/log" && [ "$(cnt 'runs/21/rerun')" = 5 ] && [ ! -s "$T/state/o__r.lease.tsv" ] && pass "lease: a re-run that never takes is retried 5 steps, then LEASE-RERUN-FAILED and dropped" || fail "unverified rerun ($(cnt 'runs/21/rerun') reruns)"
# (E) a run the lease already re-ran for this main run is never cancelled again (a later wave of the same main run)
reset; main 90:aaa:in_progress:
qjob jobs_90_q.json "$OLD"; sjob jobs_90_s.json "$OLD"
# 1 normal, 2 step1 queued (cancel), 3-4 two empty steps (release + re-run), 5 queued again (a new wave of main run 90): 21 is listed queued again
printf 'jobs_90_q.json\njobs_90_q.json\njobs_90_s.json\njobs_90_s.json\njobs_90_q.json\n' > "$FK/jobs_90.json.seq"; : > "$FK/jobs_90.json"
runs_json 21:feat-a:pa:201 > "$FK/prq_1.json"; printf 'prq_1.json\n' > "$FK/prq.json.seq"; : > "$FK/prq.json"
qjob jobs_21.json "$NEW"; cancelled21
run
[ "$(cnt 'runs/21/cancel')" = 1 ] && [ "$(cnt 'runs/21/rerun')" = 1 ] && pass "lease: a run already re-run under main run 90 is NOT cancelled again by a later wave of the same main run" || fail "re-cancelled ($(posts | tr '\n' ' '))"
# (F) the LIGHT pool: main's only queued job asks for ebda-mac-light; PR runs queued on the light label are cancelled too, other labels untouched
reset; main 90:aaa:in_progress:
qjobl jobs_90.json "$OLD" '["self-hosted","ebda-mac-light"]'
runs_json 31:feat-l:pl:301 32:feat-u:pu:302 > "$FK/prq.json"
qjobl jobs_31.json "$NEW" '["ebda-mac-light"]'; qjobl jobs_32.json "$NEW" '["ubuntu-latest"]'
run; has "actions/runs/31/cancel" && ! has "actions/runs/32/cancel" && pass "lease: main's queued LIGHT job takes the lease and a PR run queued on ebda-mac-light is cancelled; a run on another label is not" || fail "light pool ($(posts | tr '\n' ' '))"
grep -q "lease: cancel PR run 31 on arrival .*pool=ebda-mac-light) so main run" "$T/log" && pass "lease: the cancel log line names the LIGHT pool (pool=ebda-mac-light)" || fail "light cancel line lacks pool=ebda-mac-light: $(grep 'cancel PR run 31' "$T/log" | head -1)"
reset; main 90:aaa:in_progress:; qjobl jobs_90.json "$OLD" '["self-hosted","ebda-mac"]'
runs_json 31:feat-l:pl:301 > "$FK/prq.json"; qjobl jobs_31.json "$NEW" '["ebda-mac-light"]'
run; has "actions/runs/31/cancel" && pass "lease: a queued HEAVY main job also covers PR runs queued on the light pool (main wins both pools)" || fail "heavy main did not cover light PR runs"
# (G) RUNNER-ANY-1: the shared `ebda-mac-any` label is a lease pool BY DEFAULT (no MAIN_FIRST_LEASE_LABELS override): a queued main job asking for it takes the lease, PR runs queued on it are cancelled
reset; main 90:aaa:in_progress:; qjobl jobs_90.json "$OLD" '["self-hosted","ebda-mac-any"]'
runs_json 31:feat-a:pa:301 32:feat-u:pu:302 > "$FK/prq.json"; qjobl jobs_31.json "$NEW" '["ebda-mac-any"]'; qjobl jobs_32.json "$NEW" '["ubuntu-latest"]'
run; has "actions/runs/31/cancel" && ! has "actions/runs/32/cancel" && pass "lease: main's queued ANY-pool job takes the lease by default and a PR run queued on ebda-mac-any is cancelled; another label is not" || fail "any pool ($(posts | tr '\n' ' '))"
grep -q "lease: cancel PR run 31 on arrival .*pool=ebda-mac-any) so main run" "$T/log" && pass "lease: the cancel log line names the ANY pool (pool=ebda-mac-any)" || fail "any cancel line lacks pool=ebda-mac-any: $(grep 'cancel PR run 31' "$T/log" | head -1)"
reset; main 90:aaa:in_progress:; qjobl jobs_90.json "$OLD" '["self-hosted","ebda-mac"]'
runs_json 31:feat-a:pa:301 > "$FK/prq.json"; qjobl jobs_31.json "$NEW" '["ebda-mac-any"]'
run; has "actions/runs/31/cancel" && pass "lease: a queued HEAVY main job also covers PR runs queued on the ANY pool" || fail "heavy main did not cover any-pool PR runs"
# (H) MAIN-FIRST-MG-1: a merge-queue run (event merge_group, branch gh-readonly-queue/main/*) takes the lease like a queued main push run, and is never cancelled
mgrun() { # <id> <sha> <status>: one merge_group CI run
  echo "{\"workflow_runs\":[{\"id\":$1,\"name\":\"CI\",\"event\":\"merge_group\",\"head_branch\":\"gh-readonly-queue/main/pr-9-abc\",\"head_sha\":\"$2\",\"status\":\"$3\",\"conclusion\":null,\"created_at\":\"2026-11-14T11:30:00Z\"}]}" > "$FK/mg.json"; }
reset; main 90:aaa:completed:success; mgrun 70 mmm in_progress; qjobl jobs_70.json "$OLD" '["self-hosted","ebda-mac"]'
runs_json 31:feat-a:pa:301 > "$FK/prq.json"; qjobl jobs_31.json "$NEW" '["self-hosted","ebda-mac"]'
run; has "actions/runs/31/cancel" && ! has "actions/runs/70/cancel" && pass "merge-queue: a queued merge_group job takes the lease (main push run is done) and a PR run on the pool is cancelled; the queue run is not" || fail "merge_group lease ($(posts | tr '\n' ' '))"
grep -q "lease ACQUIRED by main run 70 (mmm)" "$T/log" && pass "merge-queue: the lease log names the merge_group run and its sha" || fail "no ACQUIRED line for the merge_group run"
# no queued job on the queue run, run still in progress between waves: the lease is KEPT for one step (hysteresis), not released at once
reset; main 90:aaa:completed:success; mgrun 70 mmm in_progress; echo '{"jobs":[{"status":"in_progress","created_at":"'"$OLD"'","labels":["self-hosted","ebda-mac"]}]}' > "$FK/jobs_70.json"
mkdir -p "$T/state"; printf '70\t%s\n' "$NOW" > "$T/state/o__r.lease"
run; grep -q "lease: main run 70 has no queued job (1/2)" "$T/log" && pass "merge-queue: between waves the lease is kept for one step" || fail "merge_group hysteresis ($(tail -3 "$T/log"))"
# (b) a merge_group run is NEVER in a cancel list: even listed as a queued run on the pool (with and without the event field), it is not cancelled; the real PR run is
reset; main 90:aaa:queued:; qjobl jobs_90.json "$OLD" '["self-hosted","ebda-mac"]'
cat > "$FK/prq.json" <<EOJ
{"workflow_runs":[
 {"id":41,"status":"queued","event":"merge_group","head_branch":"gh-readonly-queue/main/pr-9-abc","head_sha":"qqq","pull_requests":[]},
 {"id":42,"status":"queued","head_branch":"gh-readonly-queue/main/pr-8-def","head_sha":"rrr","pull_requests":[]},
 {"id":43,"status":"queued","event":"pull_request","head_branch":"feat-a","head_sha":"sss","pull_requests":[{"number":303}]}]}
EOJ
for i in 41 42 43; do qjobl "jobs_$i.json" "$NEW" '["self-hosted","ebda-mac"]'; done
run; has "actions/runs/43/cancel" && ! has "actions/runs/41/cancel" && ! has "actions/runs/42/cancel" && pass "merge-queue: a merge_group run (with or without the event field) is never cancelled by the lease; the PR run is" || fail "merge_group cancelled ($(posts | tr '\n' ' '))"
unset LV

echo "$_pass passed, $_fail failed"; [ "$_fail" = 0 ]
