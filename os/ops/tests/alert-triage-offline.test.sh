#!/usr/bin/env bash
# alert-triage: an OFFLINE run must not rewrite the dedupe memory, and a gh
# failure must not be reported as "no runs found / workflow renamed".
#
# FINDING (#197, 2026-10-03): the log held 104 runs saying "no 'CI' runs found for
# <repo> (workflow renamed?)" for ALL FOUR repos at once, next to "gmail ... nodename
# nor servname not known" and "0 still-firing". Every named workflow exists
# (verified with `gh workflow list`); store's `CI` returns runs fine online. The
# runs were OFFLINE: gh failed, stderr was discarded, and the empty result was
# treated as "everything resolved" -> alert-seen.json wiped -> the next online run
# re-alerted every open issue as NEW.
# Stubs only: gh/curl on PATH, fake HOME, notify recorder. No network.
set -uo pipefail
cd "$(dirname "$0")/.."; OPS="$(pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
_pass=0; _fail=0
pass() { echo "PASS: $1"; _pass=$((_pass+1)); }
fail() { echo "FAIL: $1"; _fail=$((_fail+1)); }
BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
case "${GH_MODE:-offline}" in
  offline) echo "error connecting to api.github.com: no such host" >&2; exit 1 ;;
  empty)   exit 0 ;;
  red)     echo "failure abcdef1234567890" ;;
esac
STUB
printf '#!/usr/bin/env bash\nexit 6\n' > "$BIN/curl"
chmod +x "$BIN/gh" "$BIN/curl"
NOTIFY_LOG="$T/notify.log"
mkrun() { local src="${1:-$OPS/alert-triage.sh}" d="$T/run-$RANDOM"; mkdir -p "$d"; cp "$src" "$d/alert-triage.sh"; ln -s "$OPS/lib" "$d/lib"
  printf '#!/usr/bin/env bash\necho "NOTIFY $*" >> "%s"\n' "$NOTIFY_LOG" > "$d/notify.sh"; chmod +x "$d/notify.sh"; printf '%s' "$d"; }
SEED='{"sentry:ebda-api:1":{"count":10,"status":"unresolved"}}'
run_at() {   # <run-dir> <GH_MODE> <NET_HOST_ONLINE 0|1> -> OUT RC HOME_USED
  : > "$NOTIFY_LOG"; local h="$T/home-$RANDOM"; mkdir -p "$h/.whisky-os-state"; echo "$SEED" > "$h/.whisky-os-state/alert-seen.json"
  OUT="$( PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin:$(dirname "$(command -v python3)")" HOME="$h" WHISKY_SERVICES_ENV=/dev/null \
      CI_REPOS="Ebda-AI-Studio/ebda-store" SENTRY_AUTH_TOKEN=fake SENTRY_PROJECTS=ebda-api \
      GH_MODE="$2" NET_HOST_ONLINE="$3" bash "$1/alert-triage.sh" --notify 2>&1 )"; RC=$?; HOME_USED="$h"
}
seen() { cat "$HOME_USED/.whisky-os-state/alert-seen.json"; }

D="$(mkrun)"
run_at "$D" offline 1
[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "host offline" && pass "offline: one 'host offline' line, exit 0" || fail "offline output: rc=$RC $OUT"
[ "$(seen)" = "$SEED" ] && pass "offline: alert-seen.json (dedupe memory) left byte-identical" || fail "offline run CLOBBERED the dedupe memory: $(seen)"
[ ! -s "$NOTIFY_LOG" ] && pass "offline: nothing paged" || fail "offline run paged: $(cat "$NOTIFY_LOG")"
echo "$OUT" | grep -q "workflow renamed" && fail "offline run blamed a workflow rename" || pass "offline: no bogus 'workflow renamed' claim"

run_at "$D" offline 0
echo "$OUT" | grep -q "gh run list FAILED for Ebda-AI-Studio/ebda-store (exit 1): error connecting" \
  && pass "online + gh error: real reason + exit code logged (not 'no runs found')" || fail "gh failure not surfaced: $OUT"

run_at "$D" empty 0
echo "$OUT" | grep -q "no 'CI' runs found for Ebda-AI-Studio/ebda-store" && ! echo "$OUT" | grep -q "FAILED for" \
  && pass "gh ok + zero runs: still reports 'no runs found' (a genuine rename is still visible)" || fail "empty-runs message: $OUT"

run_at "$D" red 0
grep -q "main CI FAILING: Ebda-AI-Studio/ebda-store @ abcdef12" "$NOTIFY_LOG" \
  && pass "online + red main CI: store CI failure is detected and paged" || fail "red CI not alerted: $(cat "$NOTIFY_LOG") / $OUT"

echo "== MUTATION CHECKS =="
M1="$T/m1.sh"; python3 - "$OPS/alert-triage.sh" "$M1" <<'PY' || fail "mutation 1 setup"
import sys; t=open(sys.argv[1]).read()
old='if [ "$CH_FAIL" -gt 0 ] && ! host_online; then'
assert old in t; open(sys.argv[2],'w').write(t.replace(old,'if false; then',1))
PY
D1="$(mkrun "$M1")"; run_at "$D1" offline 1
[ "$(seen)" != "$SEED" ] && pass "mutation 1 (offline gate removed) is caught: dedupe memory is wiped" || fail "MUTATION 1 survived"
M2="$T/m2.sh"; python3 - "$OPS/alert-triage.sh" "$M2" <<'PY' || fail "mutation 2 setup"
import sys; t=open(sys.argv[1]).read()
old='if [ "$_ci_rc" -ne 0 ]; then'
assert old in t; open(sys.argv[2],'w').write(t.replace(old,'if false; then',1))
PY
D2="$(mkrun "$M2")"; run_at "$D2" offline 0
echo "$OUT" | grep -q "FAILED for" && fail "MUTATION 2 survived" || pass "mutation 2 (gh failure not distinguished) is caught"
echo; echo "alert-triage-offline.test: $_pass passed, $_fail failed"; [ "$_fail" -eq 0 ]
