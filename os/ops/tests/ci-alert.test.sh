#!/usr/bin/env bash
# ci-alert (plan S1, incident I15): the Mac-side CI alert poller. A dead fleet leaves required checks QUEUED forever; that never
# turns red, so only a poller outside the fleet can page it. Fixture-driven: gh is replaced by CI_ALERT_RUNS_CMD.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; OPS="$(cd "$HERE/.." && pwd)"
pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1 - got '$2' want '$3'"; fail=$((fail+1)); fi; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"
NOW=1792996000
iso() { python3 -c "import time,sys;print(time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime($NOW-int(sys.argv[1]))))" "$1"; }
cat > "$TMP/notify" <<EOS
#!/bin/bash
echo "\$1 | \$2" >> "$TMP/pages"
exit \${NOTIFY_RC:-0}
EOS
chmod +x "$TMP/notify"
run() { # run <tag> <runs-json-or-@cmd>  (state dir persists per tag)
  local tag="$1" fx="$2"; shift 2
  if [ "${fx:0:1}" = "@" ]; then cmd="${fx:1}"; else printf '%s' "$fx" > "$TMP/fx-$tag"; cmd="cat $TMP/fx-$tag"; fi
  : > "$TMP/pages"
  env CI_ALERT_STATE="$TMP/st-$tag" CI_ALERT_REPOS="${REPOS:-acme/app}" CI_ALERT_NOTIFY="$TMP/notify" CI_ALERT_NOW="$NOW" \
    CI_ALERT_RUNS_CMD="$cmd" python3 "${PY:-$OPS/lib/ci_alert.py}" "$@" > "$TMP/out-$tag" 2>&1; RC=$?
  PAGES=$(wc -l < "$TMP/pages" | tr -d ' ')
}
R() { # R id status conclusion event branch age_s [attempt]
  printf '{"id":%s,"name":"CI","status":"%s","conclusion":%s,"event":"%s","head_branch":"%s","created_at":"%s","run_attempt":%s,"html_url":"https://x/%s"}' \
    "$1" "$2" "$([ "$3" = null ] && echo null || echo "\"$3\"")" "$4" "$5" "$(iso "$6")" "${7:-1}" "$1"
}

run q "[$(R 1 queued null pull_request feat/x 1500)]"
ok "1 required check QUEUED 25 min -> paged (dead-runner signature), exit 1" "$RC/$PAGES/$(grep -c 'queued' "$TMP/pages")" "1/1/1"
run q "[$(R 1 queued null pull_request feat/x 1500)]"
ok "1b same run next tick: not paged again" "$PAGES" "0"
run q2 "[$(R 2 queued null pull_request feat/x 600)]"
ok "1c queued only 10 min: quiet" "$RC/$PAGES" "0/0"
run c "[$(R 3 completed cancelled push main 100)]"
ok "2 cancelled on main (merge train cancel): never pages" "$RC/$PAGES" "0/0"
run c "[$(R 3 completed cancelled pull_request feat/x 100)]"
ok "2b cancelled PR run: never pages" "$PAGES" "0"
run m "[$(R 4 completed failure push main 100)]"
ok "3 main push failure -> paged" "$RC/$PAGES/$(grep -c 'failed-main' "$TMP/pages")" "1/1/1"
run m "[$(R 4 completed failure push main 100)]"
ok "3b the SAME run is paged once" "$PAGES" "0"
run m "[$(R 5 completed failure push main 50),$(R 4 completed failure push main 100)]"
ok "3c a NEW failing run pages, the old one does not" "$PAGES" "1"
run p "[$(R 6 completed failure pull_request feat/x 100 1)]"
ok "4 PR run red on attempt 1: quiet (a retry may fix it)" "$PAGES" "0"
run p "[$(R 6 completed failure pull_request feat/x 100 2)]"
ok "4b PR run red on attempt 2: paged" "$PAGES/$(grep -c 'failed-pr' "$TMP/pages")" "1/1"
run f "[$(R 7 completed failure push feat/x 100)]"
ok "5 failure on a plain feature-branch push: quiet" "$PAGES" "0"
run s "[$(R 8 completed failure schedule feat/x 100)]"
ok "6 nightly (schedule) failure: paged" "$PAGES" "1"
run n "[$(R 9 in_progress null push main 100),$(R 10 completed success push main 100),$(R 11 completed neutral push main 100)]"
ok "7 in_progress / success / neutral: quiet" "$RC/$PAGES" "0/0"
run u "@exit 1"
ok "8 gh unreadable -> UNKNOWN exit 3 + page (never silent green)" "$RC/$PAGES/$(grep -c 'UNKNOWN' "$TMP/pages")" "3/1/1"
run u "@exit 1"
ok "8b still unreadable: no spam inside the repeat window" "$RC/$PAGES" "3/0"
run u2 "not json"; ok "8c invalid JSON -> UNKNOWN" "$RC/$PAGES" "3/1"
run u3 '{"message":"Bad credentials"}'; ok "8d an API error object (not a list) -> UNKNOWN" "$RC/$PAGES" "3/1"
REPOS="acme/a acme/b" run mr '@if [ "$REPO" = acme/a ]; then echo "[]"; else exit 1; fi'
ok "9 one repo fine, one unreadable: exit 3, one UNKNOWN page" "$RC/$PAGES" "3/1"
NOTIFY_RC=1 run d "[$(R 12 completed failure push main 100)]"
NOTIFY_RC=0 run d "[$(R 12 completed failure push main 100)]"
ok "10 a failed delivery is retried next tick (not marked seen)" "$PAGES" "1"
run j "[$(R 13 queued null push main 3000)]" --json
ok "11 --json prints machine output" "$(python3 -c "import json;print(json.loads(open('$TMP/out-j').read())['alerted'][0].split(':')[0])")" "queued"
# 13 bursts and history
many=""; for i in 21 22 23 24 25 26 27 28; do many="$many$(R $i completed failure push main 100),"; done
run b "[${many%,}]"
ok "13 eight new failures in one tick: 5 pages + 1 summary, not 8" "$PAGES" "6"
run b "[${many%,}]"
ok "13b the burst is not re-sent next tick" "$PAGES" "0"
run h "[$(R 30 completed failure push main $((3*86400)))]"
ok "13c a 3-day-old failure is history: quiet" "$PAGES" "0"
run h2 "[$(R 31 queued null push main $((3*86400)))]"
ok "13d a run queued for 3 days still pages (queued has no age cap)" "$PAGES" "1"
# mutations
mkdir -p "$TMP/mut"; sed 's/RED = ("failure", "timed_out", "startup_failure")/RED = ("failure", "timed_out", "startup_failure", "cancelled")/' "$OPS/lib/ci_alert.py" > "$TMP/mut/a.py"
PY="$TMP/mut/a.py" run c2 "[$(R 3 completed cancelled push main 100)]"
ok "12 MC if cancelled counted as red the train's cancels would page (case 2 is a real test)" "$PAGES" "1"
sed 's/if key not in seen:/if True:/' "$OPS/lib/ci_alert.py" > "$TMP/mut/b.py"
PY="$TMP/mut/b.py" run m3 "[$(R 4 completed failure push main 100)]"; PY="$TMP/mut/b.py" run m3 "[$(R 4 completed failure push main 100)]"
ok "12b MC without dedup the same run pages every tick (case 3b is a real test)" "$PAGES" "1"
sed 's/return ("queued", f"queued {age} min") if age > QUEUED_MIN else None/return None/' "$OPS/lib/ci_alert.py" > "$TMP/mut/c.py"
PY="$TMP/mut/c.py" run q3 "[$(R 1 queued null pull_request feat/x 1500)]"
ok "12c MC without the queued rule the dead-fleet case is silent (case 1 is a real test)" "$PAGES" "0"
echo; echo "passed=$pass failed=$fail"; [ "$fail" = 0 ]
