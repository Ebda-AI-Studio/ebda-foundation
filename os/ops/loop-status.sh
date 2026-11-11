#!/usr/bin/env bash
# Ebda AI OS - loop-status.sh: one-screen status of the loop (the `ebda-loop` skill runs this at the top of every cycle).
#   loop-status.sh [--no-net]     --no-net skips GitHub, /health and the brain (offline: only local files)
# Prints: open PRs by state per repo (draft / held-for-review = label `risky` without `ai-review-passed` / ready), open `review-finding`
# issues, STILL-OPEN (approximate: list lines of the newest *still-open*.md) and FOUND (loop/REGISTER.md) counts, each service's live
# /health commit vs its repo's main tip, platform alerts in the last 24 h (brain), drain job state, and the exit-check summary.
# Services + repos come from os/config/prod-watch.json; the audit folder = $OS_HOME/../../business/ebda/audits. Read-only. Exit 0 always (it is a view).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/os-config.sh
. "$HERE/lib/os-config.sh" 2>/dev/null && os_config_load 2>/dev/null || true
NET=1; [ "${1:-}" = "--no-net" ] && NET=0
OSH="${OS_HOME:-$(cd "$HERE/../.." && pwd)}"
PW_JSON="$HERE/../config/prod-watch.json"
AUDITS="${OS_LOOP_AUDITS_DIR:-${OS_HOME:-$OSH}/../../business/ebda/audits}"
REG="$OSH/loop/REGISTER.md"
hr() { printf '%s\n' "---- $1"; }
echo "ebda-loop status  $(date -u +%Y-%m-%dT%H:%MZ)"

# repos = every commitRepo in prod-watch.json + the foundation itself
REPOS="$( { python3 -I - "$PW_JSON" <<'PY' 2>/dev/null
import json, sys
for p in json.load(open(sys.argv[1])).get("probes", []):
    if p.get("commitRepo"): print(p["commitRepo"])
PY
  echo "${OS_REPO_SLUG:-}"; } | awk 'NF && !s[$0]++')"

hr "open PRs (draft / held-for-review / ready) + open review-finding issues"
if [ "$NET" = 1 ] && command -v gh >/dev/null 2>&1; then
  for r in $REPOS; do
    gh pr list -R "$r" --state open --limit 200 --json isDraft,labels 2>/dev/null | python3 -I -c '
import json, sys
r = sys.argv[1]
try: prs = json.load(sys.stdin)
except Exception: print(f"{r}: unavailable"); raise SystemExit
d = h = rd = 0
for p in prs:
    L = {l["name"] for l in p["labels"]}
    if p["isDraft"]: d += 1
    elif "risky" in L and "ai-review-passed" not in L: h += 1
    else: rd += 1
print(f"{r}: {len(prs)} open  draft {d}  held-for-review {h}  ready {rd}")' "$r"
    n="$(gh issue list -R "$r" --state open --label review-finding --limit 200 --json number --jq length 2>/dev/null || echo '?')"
    echo "  review-finding issues open: $n"
  done
else echo "skipped (--no-net or gh missing)"; fi

hr "STILL-OPEN / FOUND"
SO="$(ls -t "$AUDITS"/*still-open*.md 2>/dev/null | head -1)"
if [ -n "$SO" ]; then echo "STILL-OPEN ~$(grep -cE '^[[:space:]]*([-*]|[0-9]+\.) ' "$SO") items  ($(basename "$SO"))"; else echo "STILL-OPEN: no *still-open*.md in $AUDITS"; fi
if [ -f "$REG" ]; then
  echo "FOUND $(awk '/^## FOUND/{f=1;next} /^## /{f=0} f && /^- / && !/add as QA finds them/' "$REG" | wc -l | tr -d ' ') items  (loop/REGISTER.md)"
else echo "FOUND: $REG missing"; fi

hr "deploy: live /health commit vs main tip"
if [ "$NET" = 1 ] && command -v gh >/dev/null 2>&1; then
  python3 -I - "$PW_JSON" <<'PY' 2>/dev/null | while IFS='|' read -r name url repo; do
import json, sys
for p in json.load(open(sys.argv[1])).get("probes", []):
    if p.get("commitRepo"): print(f'{p["name"]}|{p["url"]}|{p["commitRepo"]}')
PY
    live="$(curl -sS -m 10 "$url" 2>/dev/null | python3 -I -c 'import json,sys
try: print((json.load(sys.stdin).get("commit") or "null")[:8])
except Exception: print("unreachable")')"
    tip="$(gh api "repos/$repo/commits/main" --jq '.sha[0:8]' 2>/dev/null || echo '?')"
    case "$live" in null) v=UNKNOWN ;; unreachable) v=DOWN ;; *) if [ "${tip#"$live"}" != "$tip" ] || [ "${live#"$tip"}" != "$live" ]; then v=OK; else v="DIFFERS (path-filtered deploy? check gh run list --commit)"; fi ;; esac
    printf '%-10s live %-11s main %-9s %s\n' "$name" "$live" "$tip" "$v"
  done
else echo "skipped"; fi

hr "alerts last 24h (brain)"
PW="${EBDA_OS_DASH_PASSWORD:-$(security find-generic-password -a ahmad -s ebda-os-dash -w 2>/dev/null || true)}"
if [ "$NET" = 1 ] && [ -n "$PW" ]; then
  AUTH="$(mktemp)"; chmod 600 "$AUTH"; printf 'user = "ahmad:%s"\n' "$PW" > "$AUTH"
  curl -sS -m 20 -K "$AUTH" "${OS_BRAIN_URL:-https://os.ebda.app}/api/alerts?since=0&limit=200" 2>/dev/null | python3 -I -c '
import json, sys, time
try: a = json.load(sys.stdin)["alerts"]
except Exception: print("unavailable"); raise SystemExit
cut = (time.time() - 86400) * 1000
r = [x for x in a if x.get("at", 0) >= cut]
p1 = [x for x in r if x.get("level") == "p1"]
print(f"{len(r)} alerts, {len(p1)} p1")
for x in sorted(p1, key=lambda x: -x["at"])[:3]: print("  p1", x.get("source"), "-", str(x.get("title"))[:80])'
  rm -f "$AUTH"
else echo "skipped (no dashboard password in EBDA_OS_DASH_PASSWORD / Keychain ebda-os-dash, or --no-net)"; fi
unset PW

hr "drains (launchd)"
launchctl list 2>/dev/null | awk -v p="${OS_LAUNCHD_PREFIX:-com.ebda.os}.drain" 'index($3,p)==1{print "  "$3" pid="$1" last-exit="$2; n++} END{if(!n) print "  none loaded (start the drain scripts by hand; see the ebda-loop skill, step 3)"}'

hr "exit-check"
EC="$OSH/loop/exit-check.sh"
if [ -x "$EC" ] || [ -f "$EC" ]; then
  out="$(bash "$EC" 2>&1)"; rc=$?
  printf '%s\n' "$out" | tail -8; echo "exit-check rc=$rc ($([ "$rc" = 0 ] && echo 'ALL PASS - loop may stop' || echo 'NOT done - loop continues'))"
else echo "loop/exit-check.sh absent: run the measured checks in the ebda-loop skill, step 8"; fi
exit 0
