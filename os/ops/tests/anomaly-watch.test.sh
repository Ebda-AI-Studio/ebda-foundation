#!/usr/bin/env bash
# anomaly-watch: the alert path must EXECUTE (stub Sentry in, notify out), and
# must not run shell commands out of its own comments.
#
# THE DEFECT (#197, measured 2026-10-03): a comment inside a double-quoted
# `python3 -c "..."` mentioned a backticked word. Bash command-substitutes inside
# double quotes, so every run logged "alerted: command not found" (x1,240) and the
# python body was corrupted - the alert path was dead.
# Everything is stubbed: curl returns a canned Sentry payload, gh is a no-op,
# notify.sh records its calls, HOME is a temp dir. No network.
set -uo pipefail
cd "$(dirname "$0")/.."; OPS="$(pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
_pass=0; _fail=0
pass() { echo "PASS: $1"; _pass=$((_pass+1)); }
fail() { echo "FAIL: $1"; _fail=$((_fail+1)); }

BIN="$T/bin"; mkdir -p "$BIN"
NOW="$(python3 -c 'import datetime;print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
cat > "$BIN/curl" <<STUB
#!/usr/bin/env bash
echo '[{"id":"42","count":"7","firstSeen":"$NOW","title":"TypeError: boom in checkout"}]'
STUB
printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN/gh"; chmod +x "$BIN/curl" "$BIN/gh"
NOTIFY_LOG="$T/notify.log"

mkrun() {   # [script] -> run dir
  local src="${1:-$OPS/anomaly-watch.sh}" d="$T/run-$RANDOM"
  mkdir -p "$d"; cp "$src" "$d/anomaly-watch.sh"; ln -s "$OPS/lib" "$d/lib"
  printf '#!/usr/bin/env bash\necho "NOTIFY $*" >> "%s"\n' "$NOTIFY_LOG" > "$d/notify.sh"
  chmod +x "$d/notify.sh"; printf '%s' "$d"
}
run_aw() {   # <run-dir> -> OUT, ERR, RC  (fresh HOME each run => no dedupe state)
  : > "$NOTIFY_LOG"; local h="$T/home-$RANDOM"; mkdir -p "$h"
  ( PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin:$(dirname "$(command -v python3)")" HOME="$h" \
    WHISKY_SERVICES_ENV=/dev/null SENTRY_AUTH_TOKEN=fake SENTRY_PROJECTS="ebda-api" \
    bash "$1/anomaly-watch.sh" --notify ) >"$T/o" 2>"$T/e"
  RC=$?; OUT="$(cat "$T/o")"; ERR="$(cat "$T/e")"; HOME_USED="$h"
}

D="$(mkrun)"; run_aw "$D"
echo "$ERR" | grep -q "command not found" && fail "stderr has 'command not found': $ERR" || pass "no 'command not found' (nothing in a python body is shell-executed)"
echo "$OUT" | grep -q "NEW   \[ebda-api\].*TypeError: boom" && pass "new error class is detected and reported" || fail "NEW line missing: $OUT / $ERR"
grep -q "^NOTIFY " "$NOTIFY_LOG" && grep -q "NEW \[ebda-api\] 7x" "$NOTIFY_LOG" && pass "alert path executed: notify.sh was called with the NEW class" || fail "notify not called: $(cat "$NOTIFY_LOG")"
[ -s "$HOME_USED/.whisky-os-state/anomaly-alerted.json" ] && pass "alert-once dedupe state was written" || fail "no dedupe state"
# second run in the SAME home: already alerted -> must not re-page
: > "$NOTIFY_LOG"
( PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin:$(dirname "$(command -v python3)")" HOME="$HOME_USED" \
  WHISKY_SERVICES_ENV=/dev/null SENTRY_AUTH_TOKEN=fake SENTRY_PROJECTS="ebda-api" \
  bash "$D/anomaly-watch.sh" --notify ) >/dev/null 2>&1
[ ! -s "$NOTIFY_LOG" ] && pass "an already-alerted class does not re-page" || fail "re-paged: $(cat "$NOTIFY_LOG")"

echo "== MUTATION CHECKS =="
M1="$T/m1.sh"; python3 - "$OPS/anomaly-watch.sh" "$M1" <<'PY'
import sys
t=open(sys.argv[1]).read()
old='RES="$RES" NT="$NT" python3 -c "$PY_REPORT"'
if old not in t: sys.exit("setup: report line not found")
# re-introduce the original defect shape: a backticked word inside a double-quoted -c
open(sys.argv[2],'w').write(t.replace(old,'python3 -c "# the `alerted` set"\n'+old,1))
PY
[ $? -eq 0 ] || fail "mutation 1 setup"
D="$(mkrun "$M1")"; run_aw "$D"
echo "$ERR" | grep -q "alerted: command not found" && pass "mutation 1 (backticks in python -c) is caught" || fail "MUTATION 1 survived"

M2="$T/m2.sh"; python3 - "$OPS/anomaly-watch.sh" "$M2" <<'PY'
import sys
t=open(sys.argv[1]).read()
old="alerted.add(k)\n"
if old not in t: sys.exit("setup: dedupe not found")
open(sys.argv[2],'w').write(t.replace("if it['isNew'] and k not in alerted:","if False:",1))
PY
[ $? -eq 0 ] || fail "mutation 2 setup"
D="$(mkrun "$M2")"; run_aw "$D"
grep -q NOTIFY "$NOTIFY_LOG" && fail "MUTATION 2 survived" || pass "mutation 2 (NEW detection disabled) is caught: no alert fires"

echo; echo "anomaly-watch.test: $_pass passed, $_fail failed"
[ "$_fail" -eq 0 ]
