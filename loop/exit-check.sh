#!/usr/bin/env bash
# loop/exit-check.sh - measures the LOOP EXIT conditions (loop/LOOP.md "Exit criteria") that a machine can measure.
# Prints PASS/FAIL per condition and lists the manual ones. Exit 0 only when every measured condition passes AND --manual-ok
# is given (the controller asserts it holds evidence for the manual ones). Anything unreadable is FAIL: unknown is not pass.
#
#   loop/exit-check.sh [--manual-ok]
# Env: EXIT_REPOS (default the three Ebda product repos), EXIT_MAIN_REPO (default Ebda-AI-Studio/ebda-store: CI, health, smoke),
#      EXIT_HEALTH ("name|url|path-prefixes" lines; default api/web/admin), OS_BRAIN_URL (default https://os.ebda.app),
#      EBDA_OS_DASH_PASSWORD or Keychain item ebda-os-dash (the brain /api routes), EXIT_ALERT_HOURS (72).
set -uo pipefail
MANUAL_OK=0
case "${1:-}" in --manual-ok) MANUAL_OK=1 ;; -h|--help) sed -n 2,9p "$0" | sed 's/^# \{0,1\}//'; exit 0 ;; "") ;; *) echo "exit-check: unknown option $1" >&2; exit 2 ;; esac
REPOS="${EXIT_REPOS:-Ebda-AI-Studio/ebda-store Ebda-AI-Studio/ebda-whatsapp Ebda-AI-Studio/ebda-foundation}"
MAIN="${EXIT_MAIN_REPO:-Ebda-AI-Studio/ebda-store}"
HEALTH="${EXIT_HEALTH:-api|https://api.ebda.app/health|apps/api packages
web|https://ameliaaurum.com/health|apps/web packages/shared packages/ui
admin|https://store.ebda.app/health|apps/admin packages/shared packages/ui}"
BRAIN="${OS_BRAIN_URL:-https://os.ebda.app}"
HOURS="${EXIT_ALERT_HOURS:-72}"
fails=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; fails=$((fails + 1)); }

# 3a. no open review-finding issue in any product repo
open=0; unreadable=0
for r in $REPOS; do
  n="$(gh issue list -R "$r" -l review-finding -s open -L 200 --json number --jq length 2>/dev/null)" || n=""
  case "$n" in ''|*[!0-9]*) unreadable=$((unreadable + 1)); echo "      cannot read issues of $r" ;; *) open=$((open + n)); [ "$n" -gt 0 ] && echo "      $r: $n open review-finding" ;; esac
done
if [ "$unreadable" -gt 0 ]; then fail "3a review-finding issues: unreadable ($unreadable repo(s))"
elif [ "$open" -gt 0 ]; then fail "3a review-finding issues: $open open"
else pass "3a review-finding issues: 0 open"; fi

# 4a. main CI green on the latest commit: every check run on the tip completed success/skipped/neutral
sha="$(gh api "repos/$MAIN/commits/main" --jq .sha 2>/dev/null)" || sha=""
if [ -z "$sha" ]; then fail "4a main CI: cannot read the tip of $MAIN"
else
  bad="$(gh api "repos/$MAIN/commits/$sha/check-runs?per_page=100" --jq '[.check_runs[]|select(.status!="completed" or (.conclusion|IN("success","skipped","neutral")|not))|.name]|join(", ")' 2>/dev/null)" || bad="?"
  total="$(gh api "repos/$MAIN/commits/$sha/check-runs?per_page=100" --jq .total_count 2>/dev/null)" || total=0
  if [ "$bad" = "?" ]; then fail "4a main CI: cannot read check runs of ${sha:0:8}"
  elif [ "${total:-0}" = 0 ]; then fail "4a main CI: no check runs on ${sha:0:8} (zero checks is not green)"
  elif [ -n "$bad" ]; then fail "4a main CI: not green on ${sha:0:8}: $bad"
  else pass "4a main CI: $total checks green on ${sha:0:8}"; fi
fi

# 4b. each deploy's live /health commit = main tip, or main has no commit touching that app since the live commit
while IFS='|' read -r name url prefixes; do
  [ -n "$name" ] || continue
  live="$(curl -fsS -m 15 "$url" 2>/dev/null | python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("commit",""))' 2>/dev/null)" || live=""
  if [ -z "$sha" ] || [ -z "$live" ]; then fail "4b $name: cannot read live commit from $url"; continue; fi
  if [ "${live:0:7}" = "${sha:0:7}" ]; then pass "4b $name: live = main tip (${sha:0:8})"; continue; fi
  files="$(gh api "repos/$MAIN/compare/$live...$sha" --jq '.files[].filename' 2>/dev/null)" || files="?"
  if [ "$files" = "?" ]; then fail "4b $name: live ${live:0:8} differs from main ${sha:0:8} and the diff is unreadable"; continue; fi
  hit=""
  for pfx in $prefixes; do hit="$(printf '%s\n' "$files" | grep -m1 "^$pfx/")" && break; hit=""; done
  if [ -n "$hit" ]; then fail "4b $name: live ${live:0:8} is behind main ${sha:0:8} (e.g. $hit)"
  else pass "4b $name: live ${live:0:8} differs from the tip but no commit since touches $prefixes"; fi
done <<< "$HEALTH"

# 4c. last 3 prod-smoke-journey runs green
runs="$(gh run list -R "$MAIN" -w prod-smoke-journey.yml -L 3 --json conclusion --jq '[.[].conclusion]|join(",")' 2>/dev/null)" || runs="?"
if [ "$runs" = "success,success,success" ]; then pass "4c prod-smoke-journey: last 3 runs success"
else fail "4c prod-smoke-journey: last 3 runs = ${runs:-none} (need success,success,success)"; fi

# 6. brain: no open finding, no platform alert in the last $HOURS h (Basic auth like os/ops/alert-wait.sh)
PW="${EBDA_OS_DASH_PASSWORD:-$(security find-generic-password -s ebda-os-dash -w 2>/dev/null || true)}"
if [ -z "$PW" ]; then fail "6 brain: no dashboard password (EBDA_OS_DASH_PASSWORD or Keychain ebda-os-dash)"
else
  AUTH="$(mktemp)"; trap 'rm -f "$AUTH"' EXIT; chmod 600 "$AUTH"; printf 'user = "ahmad:%s"\n' "$PW" > "$AUTH"; unset PW
  st="$(curl -fsS -m 20 -K "$AUTH" "${BRAIN%/}/api/state" 2>/dev/null)" || st=""
  al="$(curl -fsS -m 20 -K "$AUTH" "${BRAIN%/}/api/alerts?since=0&limit=500" 2>/dev/null)" || al=""
  if [ -z "$st" ] || [ -z "$al" ]; then fail "6 brain: /api/state or /api/alerts unreadable"
  else
    # /api/state exposes the open COUNT, not severity: any open finding fails (stricter than P0/P1 on purpose)
    of="$(printf '%s' "$st" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["findings"]["open"])' 2>/dev/null)" || of="?"
    na="$(printf '%s' "$al" | python3 -I -c 'import json,sys,time
c=(time.time()-float(sys.argv[1])*3600)*1000
print(len([a for a in json.load(sys.stdin)["alerts"] if a.get("level")!="info" and float(a.get("last_at") or a.get("at") or 0)>=c]))' "$HOURS" 2>/dev/null)" || na="?"
    case "$of$na" in *'?'*) fail "6 brain: unparsable response" ;;
      *) if [ "$of" -gt 0 ] || [ "$na" -gt 0 ]; then fail "6 brain: $of open finding(s), $na non-info alert(s) in ${HOURS}h"; else pass "6 brain: 0 open findings, 0 alerts in ${HOURS}h"; fi ;;
    esac
  fi
fi

echo "---"
echo "manual: needs controller evidence  1 STILL-OPEN empty (re-triaged against main today, except BLOCKED-ON-PAPERS / Ahmad decisions)"
echo "manual: needs controller evidence  2 FOUND empty and every RE-VERIFY item CLOSED with live QA-store evidence"
echo "manual: needs controller evidence  3b every risky PR merged with ai-review-passed (label exists only from the AI review gate on)"
echo "manual: needs controller evidence  5 one full QA pass (all pages/buttons/flows, ar+en, 390/820/1280/1440) that finds nothing new"
if [ "$fails" -gt 0 ]; then echo "EXIT-CHECK: NOT MET ($fails measured condition(s) failing)"; exit 1; fi
if [ "$MANUAL_OK" = 1 ]; then echo "EXIT-CHECK: MET (measured all PASS; manual conditions asserted by the controller)"; exit 0; fi
echo "EXIT-CHECK: NOT MET (measured all PASS; manual conditions still need evidence - rerun with --manual-ok once held)"; exit 1
