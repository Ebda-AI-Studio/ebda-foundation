#!/usr/bin/env bash
# journey-monitor.sh — semantic golden-journey monitor for Whisky AI OS.
#
# Unlike checkout-monitor.sh (which probes liveness: 200s and gateway list),
# this runner asserts OUTCOMES: "the cart page rendered with items", "the
# storefront HTML has a product grid", "login returned a session token".
# A HTTP 200 with an empty body or an error div still fails here.
#
# Architecture:
#   - Journey scripts live in ops/journeys/<name>.mjs (plain Node.js, no deps).
#   - Each journey prints exactly ONE JSON line to stdout:
#       {"journey":"<name>","ok":true|false,"detail":"..."}
#     then exits 0 on success, non-zero on failure.
#   - Journeys source target URLs/creds from env (~/.whisky-services.env).
#     A journey whose required env is unset MUST print ok:true and a "skipped"
#     detail, then exit 0 (credential unblock — do not punish missing creds).
#   - This runner is fail-open: a crashed journey, missing node, or bad JSON
#     yields a warning finding — it NEVER exits non-zero.
#
# Usage:
#   ops/journey-monitor.sh              # run all journeys, write state
#   ops/journey-monitor.sh --notify     # also Telegram on failure
#   DRY_RUN=1 ops/journey-monitor.sh   # run but skip state writes
#   DRY_RUN=1 ops/journey-monitor.sh   # dry run
#   JOURNEY_DIR=/path/to/journeys ops/journey-monitor.sh   # override dir (for tests)
#
# Deps: bash 3.2+, node 18+ (optional — fail-open if absent). python3 stdlib.
#
# shellcheck source=lib/os-config.sh
# no external `dirname` anywhere before the node check: with a stripped PATH (the missing-node test, a minimal launchd environment) it is absent, the
# os-config source silently fell through to an installed copy that CI does not have (OS_SERVICES_ENV unbound, exit 1) and `cd ""` fails on newer bash.
# The runner must stay fail-open. Parameter expansion needs no binary.
_here="${BASH_SOURCE[0]%/*}"; [ "$_here" = "${BASH_SOURCE[0]}" ] && _here=.
_here="$(cd "$_here" && pwd)"
. "$_here/lib/os-config.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-config.sh" 2>/dev/null || true
command -v os_config_load >/dev/null 2>&1 && os_config_load
set -uo pipefail
cd "$_here" || exit 1

. ./lib/os-state.sh 2>/dev/null || true
. ./lib/net-probe.sh 2>/dev/null || true   # host pre-flight (2026-09-16)

# Optional env file (same pattern as checkout-monitor / other OS scripts)
# set -a: journeys run as child `node` processes. Sourced WITHOUT allexport,
# JOURNEY_STORE_STORE_URL stayed shell-local and node never saw it, so even a
# configured env file produced all-skip (#197). WHISKY_SERVICES_ENV: test seam.
SVC_ENV="${WHISKY_SERVICES_ENV:-$OS_SERVICES_ENV}"
[ -f "$SVC_ENV" ] && { set -a; . "$SVC_ENV"; set +a; } 2>/dev/null || true

DRY_RUN="${DRY_RUN:-0}"
NOTIFY=0
[ "${1:-}" = "--notify" ] && NOTIFY=1

# Allow test harness to point at a fixture journeys dir
JOURNEY_DIR="${JOURNEY_DIR:-$(pwd)/journeys}"
STATE_DIR="$HOME/.whisky-os-state"
mkdir -p "$STATE_DIR" 2>/dev/null || true

# ---- node probe (fail-open) ----
NODE_BIN=""
if command -v node >/dev/null 2>&1; then
  NODE_BIN="$(command -v node)"
fi

if [ -z "$NODE_BIN" ]; then
  echo "journey-monitor: node not found — skipping all journeys (fail-open)"
  write_status "journey-monitor" "warn" "node not installed; journeys skipped" '{"skipped":"no-node"}'
  exit 0
fi

# ---- discover journeys ----
# Collect .mjs files sorted alphabetically; exclude _template.mjs from runs
JOURNEY_FILES=()
while IFS= read -r f; do
  JOURNEY_FILES+=("$f")
done < <(find "$JOURNEY_DIR" -maxdepth 1 -name '*.mjs' ! -name '_*.mjs' 2>/dev/null | sort)

if [ "${#JOURNEY_FILES[@]}" -eq 0 ]; then
  echo "journey-monitor: no journey scripts found in $JOURNEY_DIR"
  write_status "journey-monitor" "true" "no journeys configured" '{"journeys":0}'
  exit 0
fi

# DRY_RUN: list journeys and exit
if [ "$DRY_RUN" = "1" ]; then
  echo "journey-monitor: DRY_RUN — would run ${#JOURNEY_FILES[@]} journey(s):"
  for f in ${JOURNEY_FILES[@]+"${JOURNEY_FILES[@]}"}; do echo "  $(basename "$f")"; done
  exit 0
fi

echo "journey-monitor: running ${#JOURNEY_FILES[@]} journey(s) from $JOURNEY_DIR"

FAILS=()       # journey names that emitted ok:false
WARNS=()       # journeys that crashed / emitted bad JSON
PASS_COUNT=0
SKIP_COUNT=0

run_journey() {
  local jfile="$1"
  local jname; jname="$(basename "$jfile" .mjs)"
  local raw exit_code

  # Run with a 30-second timeout; node --input-type reads from stdin → use file
  raw=$("$NODE_BIN" "$jfile" 2>/dev/null) || exit_code=$?
  exit_code="${exit_code:-0}"

  # Parse the JSON result line from stdout
  local ok detail skipped
  ok=$(printf '%s\n' "$raw" | python3 -c "
import sys, json
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        d = json.loads(line)
        print('skip' if str(d.get('skipped','')).lower() in ('true','1') else str(d.get('ok', '')).lower())
        sys.exit(0)
    except Exception:
        pass
print('parse-error')
" 2>/dev/null)

  detail=$(printf '%s\n' "$raw" | python3 -c "
import sys, json
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        d = json.loads(line)
        print(d.get('detail', ''))
        sys.exit(0)
    except Exception:
        pass
print('')
" 2>/dev/null)

  case "$ok" in
    true)
      echo "  PASS  $jname — $detail"
      PASS_COUNT=$((PASS_COUNT + 1))
      ;;
    skip)
      echo "  SKIP  $jname — $detail"
      SKIP_COUNT=$((SKIP_COUNT + 1))
      ;;
    false)
      echo "  FAIL  $jname — $detail"
      FAILS+=("$jname:${detail}")
      ;;
    *)
      # crashed / bad JSON — warn, don't block
      echo "  WARN  $jname — bad output or crash (exit $exit_code)"
      WARNS+=("$jname:bad-output exit=$exit_code")
      ;;
  esac
}

for jfile in ${JOURNEY_FILES[@]+"${JOURNEY_FILES[@]}"}; do
  run_journey "$jfile"
done

TOTAL="${#JOURNEY_FILES[@]}"
FAIL_COUNT="${#FAILS[@]}"
WARN_COUNT="${#WARNS[@]}"

echo ""
echo "journey-monitor: $TOTAL journey(s) — $PASS_COUNT pass, $FAIL_COUNT fail, $SKIP_COUNT skip, $WARN_COUNT warn"

# ---- is it the revenue paths, or is it my network? ----
# Every journey fetches over the network, so a local DNS/egress outage fails them
# ALL and would be escalated to Zero's inbox as "revenue path(s) BROKEN"
# (2026-09-16). Pre-flight only when something already failed, so a healthy run
# costs nothing.
if { [ "$FAIL_COUNT" -gt 0 ] || [ "$WARN_COUNT" -gt 0 ]; } \
   && command -v host_online >/dev/null 2>&1 && ! host_online; then
  net_host_offline_report journey-monitor "journey-monitor"
  exit 0
fi

# ---- emit findings for each failed journey ----
# 9-field finding schema: repo,class,severity,file,line,title,detail,fix,autofixable
if [ "$FAIL_COUNT" -gt 0 ] || [ "$WARN_COUNT" -gt 0 ]; then
  FINDINGS_FILE="$STATE_DIR/journey-findings.json"

  # Build findings JSON
  python3 - "$FINDINGS_FILE" "$DRY_RUN" <<PYEOF
import json, os, sys, datetime

findings_file = sys.argv[1]
dry = (sys.argv[2] == "1")

fails_raw = """$(printf '%s\n' "${FAILS[@]+"${FAILS[@]}"}" 2>/dev/null || true)"""
warns_raw = """$(printf '%s\n' "${WARNS[@]+"${WARNS[@]}"}" 2>/dev/null || true)"""
journey_dir = """$JOURNEY_DIR"""

findings = []
now = datetime.datetime.now().isoformat(timespec="seconds")

for entry in [l for l in fails_raw.splitlines() if l.strip()]:
    idx = entry.index(':') if ':' in entry else -1
    name = entry[:idx] if idx > 0 else entry
    detail = entry[idx+1:] if idx > 0 else ""
    findings.append({
        "repo": "ebda-foundation",
        "class": "journey-fail",
        "severity": "high",
        "file": os.path.join(journey_dir, name + ".mjs"),
        "line": 0,
        "title": "Golden journey FAILED: " + name,
        "detail": detail or "journey exited non-zero or asserted ok:false",
        "fix": "Check ops/journeys/" + name + ".mjs — a real user outcome is broken in production",
        "autofixable": False,
    })

for entry in [l for l in warns_raw.splitlines() if l.strip()]:
    idx = entry.index(':') if ':' in entry else -1
    name = entry[:idx] if idx > 0 else entry
    detail = entry[idx+1:] if idx > 0 else ""
    findings.append({
        "repo": "ebda-foundation",
        "class": "journey-crash",
        "severity": "medium",
        "file": os.path.join(journey_dir, name + ".mjs"),
        "line": 0,
        "title": "Journey script crashed or emitted bad JSON: " + name,
        "detail": detail,
        "fix": "Inspect ops/journeys/" + name + ".mjs — check node version, syntax, and that it emits a JSON result line",
        "autofixable": False,
    })

output = {
    "generated_at": now,
    "script": "journey-monitor.sh",
    "findings": findings,
}
if not dry:
    with open(findings_file, "w") as f:
        json.dump(output, f, indent=2)
    print("[journey-monitor] wrote %d finding(s) to %s" % (len(findings), findings_file))
else:
    print("[journey-monitor] DRY_RUN: would write %d finding(s)" % len(findings))
PYEOF

fi

# ---- write OS state + bus ----
if [ "$FAIL_COUNT" -gt 0 ]; then
  write_status "journey-monitor" "false" \
    "$FAIL_COUNT journey(s) FAILED — real user outcomes broken" \
    "{\"total\":$TOTAL,\"fail\":$FAIL_COUNT,\"warn\":$WARN_COUNT,\"pass\":$PASS_COUNT}"

  # Escalate to Zero's inbox (revenue path broken = speak it)
  if command -v emit_inbox >/dev/null 2>&1; then
    NAMES=$(printf '%s\n' ${FAILS[@]+"${FAILS[@]}"} | python3 -c "
import sys
names=[l.split(':')[0] for l in sys.stdin if l.strip()]
print(', '.join(names))
" 2>/dev/null)
    emit_inbox "Journey monitor: $FAIL_COUNT revenue path(s) BROKEN — $NAMES" \
      "{\"fail\":$FAIL_COUNT,\"journeys\":\"$NAMES\"}"
  fi
  if command -v emit_event >/dev/null 2>&1; then
    emit_event "journey-monitor" "high" \
      "Journey monitor: $FAIL_COUNT failed ($FAIL_COUNT/$TOTAL)" \
      "{\"fail\":$FAIL_COUNT,\"total\":$TOTAL}"
  fi

  if [ "$NOTIFY" = "1" ] && [ -x ./notify.sh ]; then
    ./notify.sh "🧭 Journey monitor: $FAIL_COUNT journey(s) FAILED — real user outcomes broken. See journey-findings.json." 2>/dev/null || true
  fi

elif [ "$WARN_COUNT" -gt 0 ]; then
  write_status "journey-monitor" "warn" \
    "$WARN_COUNT journey(s) crashed or emitted bad output" \
    "{\"total\":$TOTAL,\"warn\":$WARN_COUNT,\"pass\":$PASS_COUNT}"
  if command -v emit_event >/dev/null 2>&1; then
    emit_event "journey-monitor" "medium" \
      "Journey monitor: $WARN_COUNT journey(s) crashed (bad output)" \
      "{\"warn\":$WARN_COUNT,\"total\":$TOTAL}"
  fi
elif [ "$PASS_COUNT" -eq 0 ] && [ "$SKIP_COUNT" -gt 0 ]; then
  # ALL-SKIP: nothing was asserted. "0 pass / 1 skip" used to be written as
  # ok=true, i.e. a monitor that checks nothing reported healthy for weeks
  # (JOURNEY_STORE_STORE_URL unset). Say so loudly; do not page (not an outage).
  echo "journey-monitor: WARN — all $SKIP_COUNT journey(s) SKIPPED, no revenue path was checked. Set JOURNEY_STORE_STORE_URL (e.g. https://shop.example.com) in ~/.whisky-services.env — see ops/journeys/README.md."
  write_status "journey-monitor" "warn" \
    "BLIND: all $SKIP_COUNT journey(s) skipped (env unset) — nothing was checked" \
    "{\"total\":$TOTAL,\"pass\":0,\"skip\":$SKIP_COUNT,\"blind\":true}"
  if command -v emit_event >/dev/null 2>&1; then
    emit_event "journey-monitor" "medium" \
      "Journey monitor is blind: all $SKIP_COUNT journey(s) skipped (env unset)" \
      "{\"skip\":$SKIP_COUNT,\"total\":$TOTAL}"
  fi
else
  write_status "journey-monitor" "true" \
    "all $PASS_COUNT journey(s) passed ($SKIP_COUNT skipped — env unset)" \
    "{\"total\":$TOTAL,\"pass\":$PASS_COUNT,\"skip\":$SKIP_COUNT}"
fi

# Always exit 0 — fail-open; findings are on the bus, not in exit code
exit 0
