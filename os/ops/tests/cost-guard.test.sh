#!/usr/bin/env bash
# cost-guard must watch EVERY GitHub org that bills Ahmad, and must notice when
# GitHub Actions stops running jobs because of billing.
#
# THE DEFECT (measured 2026-10-15):
#   • GH_ORG was Ebda-AI-Studio only. The Whisky-11 org's Actions billing failed and
#     every GitHub-hosted job was refused at startup ("The job was not started
#     because recent account payments have failed or your spending limit needs to
#     be increased") — beethoven-menu, olounge-menu, whisky11-site and zero had no
#     CI. Nothing in the OS noticed; it was found by reading a red PR by hand.
#   • The refused runs look like ordinary red CI (conclusion=failure), so a
#     failure-count monitor reads them as "tests are broken".
#
# What this suite pins:
#   A   a billing-refused latest run in Whisky-11 is a violation naming the org + repo
#   B   a healthy org (latest run success, or a real test failure) is NOT a violation
#   C   the Advanced Security billing check runs for BOTH orgs
#   MC1 reverting to a single org makes A and C go red
#
# Nothing here touches GitHub, Neon or Telegram: gh, neonctl and notify.sh are
# stubs; HOME is a throwaway dir.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1   # -> ops/
OPS="$(pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
_pass=0; _fail=0
pass() { echo "PASS: $1"; _pass=$((_pass+1)); }
fail() { echo "FAIL: $1"; _fail=$((_fail+1)); }

BIN="$TMP/bin"; mkdir -p "$BIN" "$TMP/home"
GH_LOG="$TMP/gh-calls.log"

# gh stub. SCENARIO picks what the Whisky-11 repo's latest run looks like.
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
args="$*"
case "$args" in
  "repo list Ebda-AI-Studio"*) echo "fa-app" ;;
  "repo list Whisky-11"*)  echo "menu" ;;
  *"/settings/billing/advanced-security"*) echo "0|" ;;
  *"repos/Ebda-AI-Studio/fa-app/actions/runs"*) echo "11 success" ;;
  *"repos/Whisky-11/menu/actions/runs/"*"/jobs"*) echo "https://api.github.com/repos/Whisky-11/menu/check-runs/77" ;;
  *"repos/Whisky-11/menu/actions/runs"*)
     case "$SCENARIO" in
       billing|testfail) echo "22 failure" ;;
       *) echo "22 success" ;;
     esac ;;
  *"check-runs/77/annotations"*)
     case "$SCENARIO" in
       billing) echo "The job was not started because recent account payments have failed or your spending limit needs to be increased. Please check the 'Billing & plans' section in your settings" ;;
       *) echo "Process completed with exit code 1." ;;
     esac ;;
  *"actions/workflows"*) echo "" ;;
  *) echo "" ;;
esac
EOF
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/neonctl"
chmod +x "$BIN/gh" "$BIN/neonctl"

run_guard() { # $1 = guard script, $2 = scenario
  : > "$GH_LOG"
  mkdir -p "$TMP/ops"; cp "$1" "$TMP/ops/cost-guard.sh"; cp -R "$OPS/lib" "$TMP/ops/lib" 2>/dev/null
  printf '#!/usr/bin/env bash\necho "$@" >> "%s/notify.log"\n' "$TMP" > "$TMP/ops/notify.sh"; chmod +x "$TMP/ops/notify.sh"
  HOME="$TMP/home" PATH="$BIN:/usr/bin:/bin" GH_LOG="$GH_LOG" SCENARIO="$2" \
    bash "$TMP/ops/cost-guard.sh" > "$TMP/out.txt" 2>&1
  echo $?
}

SRC="$OPS/cost-guard.sh"

# A — billing refusal in Whisky-11 is a violation naming org + repo
rc=$(run_guard "$SRC" billing)
if [ "$rc" = "1" ] && grep -q "Whisky-11" "$TMP/out.txt" && grep -q "menu" "$TMP/out.txt" && grep -qi "billing" "$TMP/out.txt"; then
  pass "A: billing-refused Whisky-11 run is reported (rc=$rc)"
else
  fail "A: billing-refused Whisky-11 run not reported (rc=$rc): $(tr '\n' ' ' < "$TMP/out.txt")"
fi

# B — healthy and real-test-failure orgs are not violations
rc=$(run_guard "$SRC" healthy)
[ "$rc" = "0" ] && pass "B1: healthy orgs → rc 0" || fail "B1: healthy orgs → rc $rc: $(tr '\n' ' ' < "$TMP/out.txt")"
rc=$(run_guard "$SRC" testfail)
[ "$rc" = "0" ] && pass "B2: a real test failure is not a billing violation" || fail "B2: test failure misread as billing (rc=$rc)"

# C — Advanced Security billing checked for both orgs
run_guard "$SRC" healthy >/dev/null
if grep -q "orgs/Ebda-AI-Studio/settings/billing/advanced-security" "$GH_LOG" && grep -q "orgs/Whisky-11/settings/billing/advanced-security" "$GH_LOG"; then
  pass "C: Advanced Security billing checked for Ebda-AI-Studio AND Whisky-11"
else
  fail "C: Advanced Security not checked for both orgs"
fi

# MC1 — mutation: force a single org; A and C must go red
MUT="$TMP/mut-cost-guard.sh"
sed 's/^GH_ORGS="\${GH_ORGS:-Ebda-AI-Studio Whisky-11}"/GH_ORGS="Ebda-AI-Studio"/' "$SRC" > "$MUT"
if grep -q '^GH_ORGS="Ebda-AI-Studio"$' "$MUT"; then
  rc=$(run_guard "$MUT" billing)
  [ "$rc" = "0" ] && pass "MC1: single-org mutation misses the Whisky-11 billing refusal (A can fail)" || fail "MC1: mutation still caught it — test not sensitive (rc=$rc)"
else
  fail "MC1: mutation did not apply — GH_ORGS default line not found"
fi

echo "cost-guard: $_pass passed, $_fail failed"
[ "$_fail" -eq 0 ]
