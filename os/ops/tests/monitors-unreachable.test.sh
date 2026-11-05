#!/usr/bin/env bash
# Monitors: "unreachable" must never be reported as "broken".
#
# THE DEFECT (measured 2026-09-16, docs/plans/2026-09-16-monitors-unreachable-vs-broken.md):
# the Mac lost network access and several scheduled monitors reported their targets
# as broken, each naming a different, contradictory cause —
#   cf-workers-watch "could not verify the token (CF API unreachable?)"
#   deploy-drift     "Railway API query failed (check RAILWAY_API_TOKEN)"
#   services-watch   "PostHog API auth FAILED or no project — check POSTHOG_API_KEY"
# Every service was healthy minutes later. The Telegram sends failed too
# ("Could not resolve host: api.telegram.org") — the one broken thing was this Mac.
#
# What this suite pins, per docs/plans rulings M-1..M-4:
#   1. a transport failure is reported as UNREACHABLE, never "down"/"token invalid"
#   2. a real 500 from a REACHABLE service still fails and still pages (M-2)
#   3. host-offline produces ONE line, no per-service outage text, and NO page (M-1)
#   4. the credential wording only appears on a real HTTP status (M-3)
#   (the wbs/checkout/heal-watch cases and the mutation checks went with those scripts; see os/MANIFEST.md)
#
# NOTHING here touches the network, production, or Telegram: every target is
# 127.0.0.1 (a closed port for guaranteed ECONNREFUSED, or a local fixture),
# HOME is redirected to a temp dir, and notify.sh is always a recording stub.
set -uo pipefail
cd "$(dirname "$0")/.."   # -> ops/
OPS="$(pwd)"

TMP="$(mktemp -d)"
SERVER_PIDS=""
cleanup() {
  for p in $SERVER_PIDS; do kill "$p" 2>/dev/null; done
  rm -rf "$TMP"
}
trap cleanup EXIT

_pass=0; _fail=0
pass() { echo "PASS: $1"; _pass=$((_pass+1)); }
fail() { echo "FAIL: $1"; _fail=$((_fail+1)); }

FAKE_HOME="$TMP/home"; mkdir -p "$FAKE_HOME"
NOTIFY_LOG="$TMP/notify-calls.log"; : > "$NOTIFY_LOG"

CLOSED="http://127.0.0.1:1"        # guaranteed ECONNREFUSED -> curl exit 7
CLOSED2="http://127.0.0.1:2"
OFFLINE_PREFLIGHT="$CLOSED/p $CLOSED2/p"   # pre-flight sees no network at all

# start a local fixture; echoes its port
start_fixture() {   # <script> [mode]
  local script="$1" mode="${2:-}" port
  port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
  python3 "$OPS/tests/fixtures/$script" "$port" $mode > "$TMP/fixture-$port.log" 2>&1 &
  SERVER_PIDS="$SERVER_PIDS $!"
  disown 2>/dev/null || true   # keep bash job control quiet on cleanup
  local i=0
  while [ "$i" -lt 60 ]; do
    curl -sS -m 1 -o /dev/null "http://127.0.0.1:$port/" 2>/dev/null && break
    i=$((i+1)); sleep 0.1
  done
  printf '%s' "$port"
}

# mkrun <monitor.sh> [libdir] -> an isolated run dir holding the monitor, a
# stub notify.sh that only records its calls, and lib/ (symlinked, or copied
# from <libdir> when a mutation needs its own).
mkrun() {
  local mon="$1" libdir="${2:-}" d
  d="$TMP/run-${mon%.sh}-$$-${RANDOM}"
  mkdir -p "$d"
  cp "$OPS/$mon" "$d/$mon"; chmod +x "$d/$mon"
  if [ -n "$libdir" ]; then cp -R "$libdir" "$d/lib"; else ln -s "$OPS/lib" "$d/lib"; fi
  cat > "$d/notify.sh" <<EOF
#!/usr/bin/env bash
echo "NOTIFY \$*" >> "$NOTIFY_LOG"
echo "stub: sent"
EOF
  chmod +x "$d/notify.sh"
  printf '%s' "$d"
}

# `grep -c` PRINTS "0" and EXITS 1 when there are no matches, so `|| echo 0`
# fires as well and the function returns TWO lines ("0\n0"), which every numeric
# comparison below then rejects with "integer expression expected". Assign and
# let the assignment absorb the exit status instead.
notify_count() {
  local n
  n=$(grep -c '^NOTIFY' "$NOTIFY_LOG" 2>/dev/null) || n=0
  printf '%s' "${n:-0}"
}

# ── fixtures ──────────────────────────────────────────────────────────────────
OK_PORT="$(start_fixture fake-http-api.py healthy)"

ONLINE_PREFLIGHT="http://127.0.0.1:$OK_PORT/preflight"

echo "== cf-workers-watch =="

: > "$NOTIFY_LOG"
D="$(mkrun cf-workers-watch.sh)"
OUT="$TMP/cf-offline.log"
( HOME="$FAKE_HOME" CF_API_BASE="$CLOSED/client/v4" CF_API_TOKEN=fake-token-for-test \
  CF_WATCH_RETRIES=1 CF_WATCH_RETRY_SLEEP=0 \
  NET_PREFLIGHT_URLS="$OFFLINE_PREFLIGHT" NET_PREFLIGHT_TRIES=1 NET_PREFLIGHT_TIMEOUT=2 \
  bash "$D/cf-workers-watch.sh" ) > "$OUT" 2>&1

grep -qi "host offline" "$OUT" \
  && pass "cf-workers-watch: host-offline prints the blind-monitoring line" \
  || fail "cf-workers-watch: no host-offline line: $(cat "$OUT")"

if grep -qi "could not verify the token" "$OUT"; then
  fail "cf-workers-watch: raised a token question during a LOCAL network outage"
else
  pass "cf-workers-watch: no token speculation while the host is offline"
fi

[ "$(notify_count)" -eq 0 ] \
  && pass "cf-workers-watch: host-offline does NOT page" \
  || fail "cf-workers-watch: paged $(notify_count) time(s) while the host was offline"

echo
echo "== deploy-drift =="

: > "$NOTIFY_LOG"
D="$(mkrun deploy-drift.sh)"
OUT="$TMP/drift-unreach.log"
( HOME="$FAKE_HOME" SERVICES_ENV=/dev/null RAILWAY_API_TOKEN=fake-token-for-test \
  RAILWAY_API_URL="$CLOSED/graphql/v2" \
  NET_PREFLIGHT_URLS="$ONLINE_PREFLIGHT" NET_PREFLIGHT_TRIES=1 NET_PREFLIGHT_TIMEOUT=3 \
  bash "$D/deploy-drift.sh" ) > "$OUT" 2>&1

if grep -qi "check RAILWAY_API_TOKEN" "$OUT"; then
  fail "deploy-drift: told Ahmad to check RAILWAY_API_TOKEN for a TRANSPORT failure (Ruling M-3)"
else
  pass "deploy-drift: no 'check RAILWAY_API_TOKEN' on a transport failure"
fi
grep -qi "unreachable" "$OUT" \
  && pass "deploy-drift: an unreachable Railway API is worded as unreachable" \
  || fail "deploy-drift: expected unreachable wording: $(cat "$OUT")"

# host offline -> one line, no page
: > "$NOTIFY_LOG"
D="$(mkrun deploy-drift.sh)"
OUT="$TMP/drift-offline.log"
( HOME="$FAKE_HOME" SERVICES_ENV=/dev/null RAILWAY_API_TOKEN=fake-token-for-test \
  RAILWAY_API_URL="$CLOSED/graphql/v2" \
  NET_PREFLIGHT_URLS="$OFFLINE_PREFLIGHT" NET_PREFLIGHT_TRIES=1 NET_PREFLIGHT_TIMEOUT=2 \
  bash "$D/deploy-drift.sh" --notify ) > "$OUT" 2>&1
grep -qi "host offline" "$OUT" \
  && pass "deploy-drift: host-offline prints the blind-monitoring line" \
  || fail "deploy-drift: no host-offline line: $(cat "$OUT")"
[ "$(notify_count)" -eq 0 ] \
  && pass "deploy-drift: host-offline does NOT page" \
  || fail "deploy-drift: paged $(notify_count) time(s) while the host was offline"

# ---- Railway ANSWERED with a GraphQL error (HTTP 200 + errors, data=null) ----
# 2026-10-22: a revoked token surfaced for weeks as "FWB api: deployment stuck in
# status=-" plus a GitHub 404 pasted into an "OK" line. An auth error must be named
# as the token; an empty deployment list must say "no deployments", not "stuck".
RW_UNAUTH_PORT="$(start_fixture fake-railway.py unauthorized)"
RW_EMPTY_PORT="$(start_fixture fake-railway.py empty)"
for pair in "unauth:$RW_UNAUTH_PORT" "empty:$RW_EMPTY_PORT"; do
  mode="${pair%%:*}"; port="${pair#*:}"
  D="$(mkrun deploy-drift.sh)"
  ( HOME="$FAKE_HOME" SERVICES_ENV=/dev/null RAILWAY_API_TOKEN=fake-token-for-test \
    RAILWAY_API_URL="http://127.0.0.1:$port/graphql/v2" \
    NET_PREFLIGHT_URLS="$ONLINE_PREFLIGHT" NET_PREFLIGHT_TRIES=1 NET_PREFLIGHT_TIMEOUT=3 \
    bash "$D/deploy-drift.sh" ) > "$TMP/drift-$mode.log" 2>&1
done
grep -q "Railway rejected RAILWAY_API_TOKEN (Not Authorized)" "$TMP/drift-unauth.log" \
  && pass "deploy-drift: a GraphQL 'Not Authorized' is reported as a rejected token" \
  || fail "deploy-drift: GraphQL auth error not named as the token: $(cat "$TMP/drift-unauth.log")"
if grep -q "stuck in status=-" "$TMP/drift-unauth.log" "$TMP/drift-empty.log"; then
  fail "deploy-drift: still reports 'stuck in status=-' for an error/empty answer"
else
  pass "deploy-drift: no fake 'stuck in status=-' alert"
fi
grep -q "no deployments found in Railway" "$TMP/drift-empty.log" \
  && pass "deploy-drift: an empty deployment list says 'no deployments found'" \
  || fail "deploy-drift: empty list misreported: $(cat "$TMP/drift-empty.log")"
if grep -q "NO_DEPLO" "$TMP/drift-unauth.log" "$TMP/drift-empty.log"; then
  fail "deploy-drift: the NO_DEPLOYMENTS sentinel leaked into a GitHub compare"
else
  pass "deploy-drift: sentinel never treated as a commit sha"
fi

echo
echo "== services-watch =="

: > "$NOTIFY_LOG"
D="$(mkrun services-watch.sh)"
OUT="$TMP/services-unreach.log"
( HOME="$FAKE_HOME" WHISKY_SERVICES_ENV=/dev/null \
  SERVICES_WATCH_PROBES="probe_posthog probe_railway" \
  POSTHOG_API_KEY=fake-key-for-test POSTHOG_HOST="$CLOSED" \
  RAILWAY_API_TOKEN=fake-token-for-test RAILWAY_API_URL="$CLOSED/graphql/v2" \
  NET_PREFLIGHT_URLS="$ONLINE_PREFLIGHT" NET_PREFLIGHT_TRIES=1 NET_PREFLIGHT_TIMEOUT=3 \
  bash "$D/services-watch.sh" ) > "$OUT" 2>&1

if grep -qi "check POSTHOG_API_KEY" "$OUT"; then
  fail "services-watch: told Ahmad to check POSTHOG_API_KEY for a TRANSPORT failure (Ruling M-3)"
else
  pass "services-watch: no 'check POSTHOG_API_KEY' on a transport failure"
fi
if grep -qi "rotated/expired" "$OUT"; then
  fail "services-watch: claimed the Railway token was rotated/expired on a TRANSPORT failure"
else
  pass "services-watch: no 'rotated/expired' claim on a transport failure"
fi

: > "$NOTIFY_LOG"
D="$(mkrun services-watch.sh)"
OUT="$TMP/services-offline.log"
( HOME="$FAKE_HOME" WHISKY_SERVICES_ENV=/dev/null \
  SERVICES_WATCH_PROBES="probe_posthog probe_railway" \
  POSTHOG_API_KEY=fake-key-for-test POSTHOG_HOST="$CLOSED" \
  RAILWAY_API_TOKEN=fake-token-for-test RAILWAY_API_URL="$CLOSED/graphql/v2" \
  NET_PREFLIGHT_URLS="$OFFLINE_PREFLIGHT" NET_PREFLIGHT_TRIES=1 NET_PREFLIGHT_TIMEOUT=2 \
  bash "$D/services-watch.sh" ) > "$OUT" 2>&1
grep -qi "host offline" "$OUT" \
  && pass "services-watch: host-offline prints the blind-monitoring line" \
  || fail "services-watch: no host-offline line: $(cat "$OUT")"
[ "$(notify_count)" -eq 0 ] \
  && pass "services-watch: host-offline does NOT page" \
  || fail "services-watch: paged $(notify_count) time(s) while the host was offline"

echo

echo "== a missing classifier must fail LOUD, never open =="

# ops/install.sh copies lib/*.sh, so net-probe.sh travels with the monitors. But a gate that is merely DECLARED and not
# present must not silently revert to the old "any non-200 is a service fault" behaviour. Run a monitor from a dir with no lib/.
NOLIB="$TMP/nolib"; mkdir -p "$NOLIB"
cp "$OPS/deploy-drift.sh" "$NOLIB/"; chmod +x "$NOLIB/deploy-drift.sh"
: > "$NOTIFY_LOG"
OUT="$TMP/nolib.log"
( HOME="$FAKE_HOME" SERVICES_ENV=/dev/null \
  bash "$NOLIB/deploy-drift.sh" --notify ) > "$OUT" 2>&1
RC=$?
if [ "$RC" -eq 2 ] && grep -qi "FATAL" "$OUT"; then
  pass "a monitor with no lib/net-probe.sh aborts LOUDLY (exit 2 + FATAL), never runs unclassified"
else
  fail "missing net-probe.sh should abort with exit 2 + FATAL, got rc=$RC: $(cat "$OUT")"
fi

echo
echo "monitors-unreachable: $_pass passed, $_fail failed"
[ "$_fail" -eq 0 ]
