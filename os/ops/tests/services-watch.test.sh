#!/usr/bin/env bash
# services-watch: Neon probes must see NEON_API_KEY, the probe counter must never
# go negative, and a run in which NOTHING was checked must FAIL, not report OK.
#
# THE DEFECT (measured 2026-10-03, Ebda-AI-Studio/ebda-foundation#197):
#   * services-watch.sh sourced ~/.whisky-services.env WITHOUT `set -a`, so
#     NEON_API_KEY never reached neonctl -> 8/8 Neon probes "query failed".
#   * the summary was "checked $((9 - N_skip_notes))/9" -> "checked -2/9".
#   * an all-skipped run printed "OK".
# Everything is stubbed: neonctl/gh/vercel on PATH, HOME + env file in a temp dir,
# notify.sh a recorder. Nothing touches the network or production.
set -uo pipefail
cd "$(dirname "$0")/.."   # -> ops/
OPS="$(pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
_pass=0; _fail=0
pass() { echo "PASS: $1"; _pass=$((_pass+1)); }
fail() { echo "FAIL: $1"; _fail=$((_fail+1)); }

# ---- stubs --------------------------------------------------------------
BIN="$TMP/bin"; mkdir -p "$BIN"
SEEN="$TMP/neon-key-seen"
cat > "$BIN/neonctl" <<STUB
#!/usr/bin/env bash
# real neonctl authenticates from NEON_API_KEY in ITS environment
echo "\${NEON_API_KEY:-}" > "$SEEN"
[ -n "\${NEON_API_KEY:-}" ] || { echo "unauthorized" >&2; exit 1; }
case "\$1 \$2" in
  "projects list") echo "crimson-king-40424588"; echo "spring-dew-80973306" ;;
  "branches list") echo '{"branches":[{"name":"main"}]}' ;;
esac
STUB
printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN/gh"
chmod +x "$BIN/neonctl" "$BIN/gh"

NOTIFY_LOG="$TMP/notify.log"; : > "$NOTIFY_LOG"
mkrun() {   # <script-under-test> -> isolated run dir; $1 may be a mutated copy
  local src="${1:-$OPS/services-watch.sh}" d="$TMP/run-$RANDOM"
  mkdir -p "$d"; cp "$src" "$d/services-watch.sh"; ln -s "$OPS/lib" "$d/lib"
  printf '#!/usr/bin/env bash\necho "NOTIFY $*" >> "%s"\n' "$NOTIFY_LOG" > "$d/notify.sh"
  chmod +x "$d/notify.sh"; printf '%s' "$d"
}
ENVF="$TMP/svc.env"; echo 'NEON_API_KEY=test-neon-key' > "$ENVF"   # plain KEY=value, no `export`
FAKE_HOME="$TMP/home"; mkdir -p "$FAKE_HOME"

# run_sw <run-dir> <env-file> -> sets RC and OUT
run_sw() {
  OUT="$TMP/out-$RANDOM.log"
  ( PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin:$(dirname "$(command -v python3)")" HOME="$FAKE_HOME" \
    WHISKY_SERVICES_ENV="$2" SERVICES_WATCH_PROBES="${PROBES:-probe_neon}" \
    bash "$1/services-watch.sh" ) > "$OUT" 2>&1
  RC=$?
}

echo "== env file reaches child processes =="
rm -f "$SEEN"; D="$(mkrun)"; PROBES="probe_neon" run_sw "$D" "$ENVF"
[ "$(cat "$SEEN" 2>/dev/null)" = "test-neon-key" ] \
  && pass "neonctl received NEON_API_KEY from the env file" \
  || fail "neonctl did NOT see NEON_API_KEY (got '$(cat "$SEEN" 2>/dev/null)')"
grep -q "checked 1/1 service probes" "$OUT" && [ "$RC" -eq 0 ] \
  && pass "neon probe ran: 'checked 1/1', exit 0" || fail "expected 'checked 1/1' exit 0, rc=$RC: $(cat "$OUT")"

echo "== counter never negative =="
D="$(mkrun)"; PROBES="probe_neon" run_sw "$D" /dev/null     # no key -> every neonctl call fails
grep -qE 'checked -[0-9]' "$OUT" && fail "negative counter: $(grep checked "$OUT")" || pass "no negative 'checked' count with failing neon queries"

echo "== all-skipped is FAILURE =="
D="$(mkrun)"; PROBES="probe_neon" run_sw "$D" /dev/null
[ "$RC" -ne 0 ] && pass "all probes skipped -> non-zero exit (rc=$RC)" || fail "all-skipped exited 0"
grep -q "BLIND" "$OUT" && ! grep -q "OK — no cost/health" "$OUT" \
  && pass "all-skipped says BLIND, never OK" || fail "all-skipped output: $(cat "$OUT")"
grep -q '"ok": *true' "$FAKE_HOME/.whisky-os-state/services-status.json" 2>/dev/null \
  && fail "status file says ok=true for an all-skipped run" || pass "status file is not ok=true for an all-skipped run"
grep -q NOTIFY "$NOTIFY_LOG" && pass "all-skipped pages" || fail "all-skipped did not notify"

echo "== MUTATION CHECKS =="
M1="$TMP/m1.sh"; python3 - "$OPS/services-watch.sh" "$M1" <<'PY'
import sys
t=open(sys.argv[1]).read()
old='{ set -a; . "$SVC_ENV"; set +a; }'
if old not in t: sys.exit("mutation setup failed: set -a not found")
open(sys.argv[2],'w').write(t.replace(old,'. "$SVC_ENV"',1))
PY
[ $? -eq 0 ] || fail "mutation 1 setup"
rm -f "$SEEN"; D="$(mkrun "$M1")"; PROBES="probe_neon" run_sw "$D" "$ENVF"
[ "$(cat "$SEEN" 2>/dev/null)" = "test-neon-key" ] \
  && fail "MUTATION 1 (drop set -a) survived: env-export test is not load-bearing" \
  || pass "mutation 1 (drop set -a) is caught"

M2="$TMP/m2.sh"; python3 - "$OPS/services-watch.sh" "$M2" <<'PY'
import sys
t=open(sys.argv[1]).read()
old='[ "$probes_ran" -eq 0 ]'
if old not in t: sys.exit("mutation setup failed: all-skipped guard not found")
open(sys.argv[2],'w').write(t.replace(old,'[ "$probes_ran" -lt 0 ]',1))
PY
[ $? -eq 0 ] || fail "mutation 2 setup"
D="$(mkrun "$M2")"; PROBES="probe_neon" run_sw "$D" /dev/null
[ "$RC" -eq 0 ] \
  && pass "mutation 2 (disable all-skipped guard) is caught: it exits 0, the test above would redden" \
  || fail "MUTATION 2 survived"

echo; echo "services-watch.test: $_pass passed, $_fail failed"
[ "$_fail" -eq 0 ]
