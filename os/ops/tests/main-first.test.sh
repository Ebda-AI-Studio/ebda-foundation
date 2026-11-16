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
if [ "$method" = POST ]; then echo "$path" >> "$FK/posts.log"; echo '{}'; exit 0; fi
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
  */pulls\?head=*) b="${path#*head=*:}"; b="${b%%&*}"; f="openpr_${b}.json" ;;
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
  echo "{\"runs\":[${a%,}]}" > "$FK/main.json"; }
jobs() { echo "{\"jobs\":[{\"status\":\"queued\",\"created_at\":\"$2\",\"labels\":[\"self-hosted\",\"ebda-mac\"]}]}" > "$FK/jobs_$1.json"; }
prq() { local a="" s i br sha n; for s in "$@"; do IFS=: read -r i br sha n <<<"$s"; a="$a{\"id\":$i,\"status\":\"queued\",\"head_branch\":\"$br\",\"head_sha\":\"$sha\",\"pull_requests\":[{\"number\":$n}]},"; done
  echo "{\"runs\":[${a%,}]}" > "$FK/prq.json"; }
run() { FAKE_DIR="$FK" PATH="$BIN:$PATH" HOME="$T/home" MAIN_FIRST_REPOS="o/r" MAIN_FIRST_STATE="$T/state" MAIN_FIRST_LOG="$T/log" MAIN_FIRST_NOW="$NOW" MAIN_FIRST_VERIFY_WAIT=0 MAIN_FIRST_ALLOW_BRANCHES="${ALLOW:-}" bash "$OPS/main-first.sh" "$@" >"$T/out" 2>&1; }
posts() { cat "$FK/posts.log" 2>/dev/null; }
has() { posts | grep -q -F "$1"; }

# 1. main queued 30m + PR queued -> PR cancelled + one comment
reset; main 90:aaa:queued:; jobs 90 "$OLD"; prq 11:feat-x:p1:101; jobs 11 "$NEW"
run
has "actions/runs/11/cancel" && has "issues/101/comments" && ! has "actions/runs/90/cancel" && pass "queued PR run cancelled, comment left, main untouched" || fail "queued PR cancel ($(posts | tr '\n' ' '))"
run   # second tick: queued PR run is still listed (fake) -> comment must not repeat
[ "$(posts | grep -c issues/101/comments)" = 1 ] && pass "comment once per head" || fail "comment repeated"

# 2. in_progress PR run untouched (not in the queued listing; also a non-heavy queued run)
reset; main 90:aaa:queued:; jobs 90 "$OLD"; echo '{"runs":[]}' > "$FK/prq.json"
run; [ -z "$(posts)" ] && pass "in_progress PR run untouched (not listed as queued)" || fail "in_progress touched"
reset; main 90:aaa:queued:; jobs 90 "$OLD"; prq 12:feat-y:p2:102
echo '{"jobs":[{"status":"queued","created_at":"'"$NEW"'","labels":["ubuntu-latest"]}]}' > "$FK/jobs_12.json"
run; [ -z "$(posts)" ] && pass "queued PR run without the heavy label untouched" || fail "non-heavy cancelled"

# 3. superseded main cancelled, newest kept; non-ancestor kept
reset; main 93:ccc:queued: 92:bbb:in_progress: 91:zzz:queued:; jobs 93 "$OLD"
echo '{"status":"ahead"}' > "$FK/cmp_bbb.json"; echo '{"status":"diverged"}' > "$FK/cmp_zzz.json"; echo '{"runs":[]}' > "$FK/prq.json"
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
echo '{"runs":[{"id":11,"status":"queued","head_branch":"gone","head_sha":"p1","pull_requests":[],"created_at":"2026-11-12T00:00:00Z"},{"id":12,"status":"queued","head_branch":"live","head_sha":"p2","pull_requests":[{"number":102}],"created_at":"2026-11-12T00:00:00Z"}]}' > "$FK/prq.json"
echo '[]' > "$FK/openpr_gone.json"; echo '[{"number":102}]' > "$FK/openpr_live.json"; echo '{"status":"completed"}' > "$FK/run_12.json"
run
has "actions/runs/12/cancel" && ! has "actions/runs/11/cancel" && grep -q "orphan run 11" "$T/log" && pass ">24h orphan skipped + logged; >24h with open PR still cancelled" || fail "orphan ($(posts | tr '\n' ' '))"

# 9. main completed red -> nothing re-run
reset; main 95:ddd:completed:failure; mkdir -p "$T/state"; printf '11\t101\tp1\t%s\n' "$NOW" > "$T/state/o__r.cancelled.tsv"
run; [ -z "$(posts)" ] && [ -s "$T/state/o__r.cancelled.tsv" ] && pass "main red -> ledger kept, no re-run" || fail "red main"

echo "$_pass passed, $_fail failed"; [ "$_fail" = 0 ]
