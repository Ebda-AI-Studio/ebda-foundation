#!/usr/bin/env bash
# main-first.sh cross-repo fairness (G16): when repo A's main CI starves, queued PR runs of the OTHER repos on the shared runner pool are
# cancelled round-robin by repo (capped), main-before-PR stays first, and the repo order rotates each tick.
# Before 2026-11-15 only the starved repo's own PR runs were cancelled, so another repo's backlog starved its main CI.
set -uo pipefail
OPS="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; _pass=0; _fail=0
pass() { echo "PASS: $1"; _pass=$((_pass+1)); }
fail() { echo "FAIL: $1"; tail -5 "$T/log" 2>/dev/null; _fail=$((_fail+1)); }
trap 'rm -rf "$T"' EXIT
BIN="$T/bin"; FK="$T/fake"; mkdir -p "$BIN" "$FK" "$T/home"
# repo-aware fake gh: repos/o/<name>/<rest> -> $FK/<name>.<kind>
cat > "$BIN/gh" <<'FAKE'
#!/usr/bin/env bash
FK="${FAKE_DIR:?}"
[ "${1:-}" = api ] || exit 1
shift; method=GET; path=""
while [ $# -gt 0 ]; do case "$1" in -X) method="$2"; shift ;; -f) shift ;; *) [ -z "$path" ] && path="$1" ;; esac; shift; done
if [ "$method" = POST ]; then echo "$path" >> "$FK/posts.log"; echo '{}'; exit 0; fi
rest="${path#repos/o/}"; name="${rest%%/*}"; r="${rest#*/}"; f=""
case "$r" in
  actions/runs\?branch=main*) f=main ;;
  actions/runs\?status=queued*) f=prq ;;
  actions/runs/*/jobs*) id="${r#actions/runs/}"; f="jobs_${id%%/*}" ;;
  issues/*/labels) f="nolabels" ;;
  actions/runs/[0-9]*) f="run_${r#actions/runs/}" ;;
esac
[ "$f" = nolabels ] && { echo '[]'; exit 0; }
[ -f "$FK/$name.$f.json" ] && cat "$FK/$name.$f.json" || { [ -f "$FK/any.$f.json" ] && cat "$FK/any.$f.json" || exit 1; }
FAKE
chmod +x "$BIN/gh"
NOW=1794657600; OLD="2026-11-14T11:30:00Z"; NEW="2026-11-14T11:58:00Z"
wj() { echo "$2" > "$FK/$1.json"; }
queued_job() { echo "{\"jobs\":[{\"status\":\"queued\",\"created_at\":\"$2\",\"labels\":[\"self-hosted\",\"ebda-mac\"]}]}" > "$FK/any.jobs_$1.json"; }
# prq <repo> id:branch:sha:pr ...
prq() { local repo="$1" a="" s i br sha n; shift; for s in "$@"; do IFS=: read -r i br sha n <<<"$s"; a="$a{\"id\":$i,\"status\":\"queued\",\"event\":\"pull_request\",\"head_branch\":\"$br\",\"head_sha\":\"$sha\",\"created_at\":\"2026-11-14T11:5$((i%10)):00Z\",\"pull_requests\":[{\"number\":$n}]},"; done
  wj "$repo.prq" "{\"workflow_runs\":[${a%,}]}"; }
run() { FAKE_DIR="$FK" PATH="$BIN:$PATH" HOME="$T/home" MAIN_FIRST_REPOS="o/a o/b o/c" MAIN_FIRST_STATE="$T/state" MAIN_FIRST_LOG="$T/log" MAIN_FIRST_NOW="$NOW" MAIN_FIRST_VERIFY_WAIT=0 MAIN_FIRST_FAIR_CAP="${CAP:-3}" MAIN_FIRST_FAIR_TOTAL="${TOTAL:-6}" bash "$OPS/main-first.sh" >"$T/out" 2>&1; }
posts() { cat "$FK/posts.log" 2>/dev/null; }
reset() { rm -rf "${FK:?}"/* "$T/state" "$T/log"
  # main CI: a starved (newest run queued, job queued 30 m); b and c green
  wj a.main '{"workflow_runs":[{"id":90,"name":"CI","head_sha":"aaa","status":"queued","conclusion":null,"created_at":"2026-11-14T11:30:00Z"}]}'; queued_job 90 "$OLD"
  for r in b c; do wj $r.main '{"workflow_runs":[{"id":91,"name":"CI","head_sha":"bbb","status":"completed","conclusion":"success","created_at":"2026-11-14T11:30:00Z"}]}'; done
  wj a.prq '{"workflow_runs":[]}'; }

# 1. a is starved; b has a backlog of 5, c of 2 -> both pay, capped at 3 per repo, round-robin (b,c,b,c,b), total 5 here
reset; prq b 101:fb1:s1:1 102:fb2:s2:2 103:fb3:s3:3 104:fb4:s4:4 105:fb5:s5:5; prq c 201:fc1:t1:11 202:fc2:t2:12
for i in 101 102 103 104 105 201 202; do queued_job $i "$NEW"; done
run
order="$(posts | grep '/cancel$' | sed 's#.*/o/\(.\)/actions/runs/\([0-9]*\)/cancel#\1\2#' | tr '\n' ' ')"
[ "$(posts | grep -c '/cancel$')" = 5 ] && [ "$(posts | grep -c 'o/b/actions/runs/.*/cancel')" = 3 ] && [ "$(posts | grep -c 'o/c/actions/runs/.*/cancel')" = 2 ] \
  && pass "other repos' queued PR runs cancelled for a's starved main, capped 3 per repo ($order)" || fail "fair cancel ($order)"
case "$order" in b*" c"*" b"*) pass "round-robin: repos alternate (not all of b first)";; *) fail "not round-robin: $order";; esac
grep -q 'actions/runs/90/cancel' < <(posts) && fail "main run was cancelled" || pass "main CI itself is never cancelled"
# 2. total cap
reset; prq b 101:fb1:s1:1 102:fb2:s2:2 103:fb3:s3:3; prq c 201:fc1:t1:11 202:fc2:t2:12 203:fc3:t3:13
for i in 101 102 103 201 202 203; do queued_job $i "$NEW"; done
TOTAL=4 run; [ "$(posts | grep -c '/cancel$')" = 4 ] && pass "FAIR_TOTAL bounds cancels per starved repo per tick" || fail "total cap ($(posts | grep -c '/cancel$'))"
# 3. NEGATIVE: a run with a started job is kept; main not starved -> no cross-repo action
reset; prq b 101:fb1:s1:1; echo '{"jobs":[{"status":"in_progress","labels":["ebda-mac"]},{"status":"queued","created_at":"'"$NEW"'","labels":["ebda-mac"]}]}' > "$FK/any.jobs_101.json"
run; [ -z "$(posts | grep '/cancel$')" ] && pass "partially started run of another repo is kept" || fail "started run cancelled"
reset; wj a.main '{"workflow_runs":[{"id":90,"name":"CI","head_sha":"aaa","status":"queued","conclusion":null,"created_at":"2026-11-14T11:30:00Z"}]}'; queued_job 90 "$NEW"
prq b 101:fb1:s1:1; queued_job 101 "$NEW"; run; [ -z "$(posts)" ] && pass "main not starved: other repos untouched" || fail "acted without starvation"
# 4. cancelled runs land in the OWNING repo's ledger, with a comment on its PR
reset; prq b 101:fb1:s1:1; queued_job 101 "$NEW"; run
grep -qx 101 < <(cut -f1 "$T/state/o__b.cancelled.tsv" 2>/dev/null) && grep -q 'o/b/issues/1/comments' < <(posts) && pass "run recorded in b's ledger + comment on b's PR" || fail "ledger/comment"
# 5. rotation: cursor advances each tick
reset; run; c1="$(cat "$T/state/rr-cursor")"; run; c2="$(cat "$T/state/rr-cursor")"
[ "$c1" = 1 ] && [ "$c2" = 2 ] && grep -q 'tick start' "$T/log" && pass "repo order cursor advances every tick" || fail "cursor $c1 $c2"
echo "main-first-fairness: $_pass passed, $_fail failed"; [ "$_fail" = 0 ]
