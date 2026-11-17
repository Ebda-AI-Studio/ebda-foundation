#!/usr/bin/env bash
# ci-runner-guard.sh — fleet health is judged from the GitHub API (native Mac runners).
# A fake `gh` on PATH serves `gh api orgs/<org>/actions/runners` from fixture files; a throwaway HOME;
# notify.sh stubbed so nothing pages. Regression target (2026-11-14): the guard read an Umbra
# "fleet parked" marker and raised a false "CI will queue FOREVER" alarm while the Mac runners were online.
set -uo pipefail
OPS="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"
_pass=0; _fail=0
pass() { echo "PASS: $1"; _pass=$((_pass+1)); }
fail() { echo "FAIL: $1"; _fail=$((_fail+1)); }
trap 'rm -rf "$T"' EXIT

G="$T/ops"; BIN="$T/bin"; FK="$T/fake"
mkdir -p "$G/lib" "$BIN" "$FK" "$T/home"
cp "$OPS/ci-runner-guard.sh" "$G/"
cp "$OPS/lib/"*.sh "$G/lib/"
printf '#!/bin/sh\necho CALL >> "%s/notify.count"\necho "$*" >> "%s/notify.log"\n' "$FK" "$FK" > "$G/notify.sh"
chmod +x "$G/notify.sh"

# fake gh: `gh api orgs/<org>/actions/runners...` prints $FK/<org>.json (exit 1 when absent = API failure).
cat > "$BIN/gh" <<'FAKE'
#!/usr/bin/env bash
FK="${FAKE_DIR:?}"
echo "$*" >> "$FK/gh.log"
case "$*" in
  api\ orgs/*/actions/runners*)
    org="${2#orgs/}"; org="${org%%/*}"
    [ -f "$FK/$org.json" ] || exit 1
    cat "$FK/$org.json" ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$BIN/gh"

# runners <org> name:status:busy:label ... -> writes the org fixture
runners() {
  local org="$1"; shift
  python3 - "$FK/$org.json" "$@" <<'PY'
import sys, json
out, specs = sys.argv[1], sys.argv[2:]
rs = []
for s in specs:
    n, st, b, lab = s.split(":")
    rs.append({"name": n, "status": st, "busy": b == "true",
               "labels": [{"name": "self-hosted"}, {"name": "macOS"}, {"name": lab}]})
json.dump({"total_count": len(rs), "runners": rs}, open(out, "w"))
PY
}

run_guard() {
  rm -f "$FK/notify.log" "$FK/notify.count"
  env HOME="$T/home" PATH="$BIN:$PATH" FAKE_DIR="$FK" HOST_DISK_WARN_PCT=101 HOST_DISK_CRIT_PCT=101 \
    RUNNER_ORGS="${RUNNER_ORGS_T:-Org-A}" "$@" bash "$G/ci-runner-guard.sh" >"$T/guard.out" 2>&1
  return $?
}

# ── 1. online runners => healthy, exit 0, no page (the 2026-11-14 false alarm) ───────────
runners Org-A m1:online:true:ebda-mac m2:online:true:ebda-mac l1:online:false:ebda-mac-light
run_guard; rc=$?
if [ "$rc" -eq 0 ] && grep -q 'OK' "$T/guard.out" && grep -q '3/3 runners online' "$T/guard.out" && [ ! -s "$FK/notify.log" ]; then
  pass "all runners online (even all busy) -> exit 0, no page"
else fail "online fleet not reported healthy (rc=$rc)"; sed 's/^/        /' "$T/guard.out" | head; fi

# ── 2. a stale Umbra park marker must not matter any more ───────────────────────────────
mkdir -p "$T/home/.whisky-os-state"; echo "Ruling CI-PAUSE-UMBRA-1 parked" > "$T/home/.whisky-os-state/runner-fleet-paused"
run_guard; rc=$?
if [ "$rc" -eq 0 ] && ! grep -qiE 'parked|umbra|USE_SELF_HOSTED' "$T/guard.out"; then
  pass "a leftover runner-fleet-paused marker is ignored"
else fail "park marker still influences the guard (rc=$rc)"; sed 's/^/        /' "$T/guard.out" | head -4; fi
rm -f "$T/home/.whisky-os-state/runner-fleet-paused"

# ── 3. every runner of the org offline => finding, exit 1, one page ─────────────────────
runners Org-A m1:offline:false:ebda-mac m2:offline:false:ebda-mac
run_guard; rc=$?
if [ "$rc" -eq 1 ] && grep -q 'ALL 2 runner(s) OFFLINE' "$T/guard.out" && [ "$(wc -l < "$FK/notify.count" | tr -d ' ')" = 1 ]; then
  pass "all org runners offline -> exit 1, named finding, paged exactly once"
else fail "all-offline fleet not alerted (rc=$rc)"; sed 's/^/        /' "$T/guard.out" | head; fi

# ── 4. one pool dead while another is up => finding for that label ──────────────────────
runners Org-A m1:offline:false:ebda-mac m2:offline:false:ebda-mac l1:online:false:ebda-mac-light
run_guard; rc=$?
if [ "$rc" -eq 1 ] && grep -q "label 'ebda-mac'" "$T/guard.out" && ! grep -q "label 'ebda-mac-light'" "$T/guard.out"; then
  pass "a whole label pool offline is a finding for that pool only"
else fail "dead pool not isolated (rc=$rc)"; sed 's/^/        /' "$T/guard.out" | head; fi

# ── 5. partially offline => note only ────────────────────────────────────────────────────
runners Org-A m1:online:false:ebda-mac m2:offline:false:ebda-mac
run_guard; rc=$?
if [ "$rc" -eq 0 ] && grep -q 'offline: m2' "$T/guard.out"; then pass "one runner offline of a live pool is a note, not an alert"
else fail "partial outage mishandled (rc=$rc)"; sed 's/^/        /' "$T/guard.out" | head -4; fi

# ── 6. API failure is UNKNOWN, never 'all offline' ───────────────────────────────────────
rm -f "$FK/Org-A.json"
run_guard; rc=$?
if [ "$rc" -eq 0 ] && grep -q 'NOT evaluated' "$T/guard.out" && [ ! -s "$FK/notify.log" ]; then pass "unreadable runner list -> noted as not evaluated, no false page"
else fail "API failure treated as an outage (rc=$rc)"; sed 's/^/        /' "$T/guard.out" | head -4; fi

# ── 7. an org with no runners is nothing to guard ────────────────────────────────────────
echo '{"total_count":0,"runners":[]}' > "$FK/Org-A.json"
run_guard; rc=$?
[ "$rc" -eq 0 ] && grep -q 'nothing to guard' "$T/guard.out" && pass "org with zero registered runners -> note, exit 0" || fail "empty org mishandled (rc=$rc)"

# ── 8. multiple orgs are each judged ─────────────────────────────────────────────────────
runners Org-A m1:online:false:ebda-mac
runners Org-B f1:offline:false:other-mac
RUNNER_ORGS_T="Org-A Org-B" run_guard; rc=$?
[ "$rc" -eq 1 ] && grep -q 'Org-B: ALL 1 runner' "$T/guard.out" && ! grep -q 'Org-A: ALL' "$T/guard.out" \
  && pass "each org in RUNNER_ORGS is judged independently" || { fail "multi-org (rc=$rc)"; sed 's/^/        /' "$T/guard.out" | head; }

# ── 9. host disk crit is still a finding ─────────────────────────────────────────────────
runners Org-A m1:online:false:ebda-mac
run_guard HOST_DISK_WARN_PCT=0 HOST_DISK_CRIT_PCT=1; rc=$?
[ "$rc" -eq 1 ] && grep -q 'HOST disk' "$T/guard.out" && pass "critical host disk is a finding" || { fail "host disk crit not alerted (rc=$rc)"; sed 's/^/        /' "$T/guard.out" | head -4; }

# ── 10. _ut (shared wall-clock helper) keeps stdin and returns the command's code ────────
# shellcheck source=/dev/null
. "$OPS/lib/os-state.sh"
got="$(printf 'hello\n' | _ut 5 cat)"
[ "$got" = "hello" ] && pass "_ut passes stdin through" || fail "_ut dropped stdin ('$got')"
_ut 5 sh -c 'exit 3'; [ $? = 3 ] && pass "_ut returns the command's exit code" || fail "_ut exit code"

# ── 11. no Umbra machinery left in the guard ─────────────────────────────────────────────
if ! grep -qiE 'umbra|fleet_parked|USE_SELF_HOSTED|OS_VM' < <(grep -vE '^[[:space:]]*#' "$OPS/ci-runner-guard.sh"); then
  pass "guard code has no umbra / park / USE_SELF_HOSTED logic"
else fail "umbra-era logic crept back into the guard"; fi

echo "ci-runner-guard: $_pass passed, $_fail failed"
[ "$_fail" -eq 0 ]
