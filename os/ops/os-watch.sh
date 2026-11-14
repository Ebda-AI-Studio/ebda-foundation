#!/usr/bin/env bash
# Whisky AI OS — delivery-health watch (the autonomous oversight heartbeat).
# Read-only. Complements services-watch.sh (which covers COST + uptime/observability)
# by watching the GIT / CI DELIVERY state across every Force repo, so the OS notices
# breakage on its own instead of waiting for Ahmad to look:
#
#   1. main CI red                — a push to main left CI failing (real breakage)
#   2. "was-green-now-red"        — main flipped from passing to failing = a regression
#   3. open PR red / stuck        — a PR with failing checks sitting open
#   4. self-hosted runners offline — queued CI on that repo will stall
#
# It NEVER mutates anything (no merges, no pushes, no branch ops). When it finds
# something actionable it fires ONE Telegram digest via notify.sh. The reasoning/
# fix tier (anomaly-diff, dreaming, auto-PR) layers on top of this signal later —
# this is the deterministic substrate that makes "the OS runs independently" true.
#
# Schedule: launchd ${OS_LAUNCHD_PREFIX}.os-watch (every 2h). Runs on the Mac independent of
# any Claude session. State for the green→red anomaly lives in ~/.whisky-os-state/.
# shellcheck source=lib/os-config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/os-config.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-config.sh" 2>/dev/null || true
command -v os_config_load >/dev/null 2>&1 && os_config_load
set -uo pipefail
# S0 (2026-10-26): --help runs nothing; one run at a time (lib/single-instance.sh)
. "$(dirname "${BASH_SOURCE[0]}")/lib/args.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/args.sh" || exit 2
. "$(dirname "${BASH_SOURCE[0]}")/lib/single-instance.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/single-instance.sh" || exit 2
args_help "${BASH_SOURCE[0]}" "$@"
single_instance os-watch

HERE="$(cd "$(dirname "$0")" && pwd)"
GH_USER="$OS_ORG"
NOTIFY="$HERE/notify.sh"
STATE_DIR="${WHISKY_OS_STATE:-$HOME/.whisky-os-state}"
mkdir -p "$STATE_DIR" 2>/dev/null || true
# Live Companion OS bus — emit a "speak this now" inbox item on a real
# regression (green→red), so the OS surfaces breakage live instead of waiting
# for the Telegram digest. Fail-open (sourced best-effort).
. "$HERE/lib/os-state.sh" 2>/dev/null || true

# Repos the OS oversees: the "repos" list in ~/.ebda-os.local.json (see os/config/local.example.json).
REPOS=()
while IFS= read -r _r; do [ -n "$_r" ] && REPOS+=("$_r"); done < <(os_local_list repos ebda-store ebda-whatsapp ebda-studio)
# Self-hosted runner repos (the rest use cloud runners only).
SELFHOSTED_REPOS=(ebda-store ebda-whatsapp)

findings=()   # actionable problem lines
anomalies=()  # green->red regressions (louder)
note()    { findings+=("$1"); }
# A green→red regression is exactly the "watch my back" case → push it to the
# Zero inbox (deduped upstream: anomaly() only fires on the GREEN→FAILING
# transition, not every run, so the bus never floods on steady-state red).
anomaly() {
  anomalies+=("$1")
  type emit_inbox >/dev/null 2>&1 && emit_inbox "$1" '{"source":"os-watch","kind":"ci-regression"}'
  # auto-postmortem (feature #4): on a green->red regression, draft a postmortem +
  # candidate detector ONCE per incident (statefile-guarded so re-runs don't spam).
  _pm_slug="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | cut -c1-40 | sed 's/-*$//')"
  _pm_guard="$STATE_DIR/.pm-fired-${_pm_slug}"
  if [ -n "$_pm_slug" ] && [ ! -f "$_pm_guard" ] && [ -x "$HERE/postmortem.sh" ]; then
    : > "$_pm_guard" 2>/dev/null || true
    "$HERE/postmortem.sh" --slug "$_pm_slug" --repo "${slug:-unknown}" --summary "$1" --severity P0 >/dev/null 2>&1 &
  fi
}

command -v gh >/dev/null || { echo "os-watch: gh CLI missing" >&2; exit 1; }

# Python program (read off -c, NOT stdin) that reduces `gh run list` JSON on stdin to
# a single verdict line: PASS|sha|  FAIL|sha|names  PENDING|sha|  NONE|..|  UNKNOWN|..|
# NOTE: the program MUST come from -c, never a heredoc — a heredoc and the gh pipe both
# target stdin and the heredoc wins, leaving json.load(stdin) empty (silent UNKNOWN).
_PY_MAIN_CI='
import sys, json
try:
    runs = json.load(sys.stdin)
except Exception:
    print("UNKNOWN||"); sys.exit(0)
GATE_EVENTS = {"push", "pull_request", "merge_group", "dynamic"}
DROP_NAMES = ("runner health", "cloud rescue")
cand = [r for r in runs
        if r.get("event") in GATE_EVENTS
        and not any(d in (r.get("name") or "").lower() for d in DROP_NAMES)]
if not cand:
    print("NONE||"); sys.exit(0)
head_sha = cand[0].get("headSha", "")
head_runs = [r for r in cand if r.get("headSha") == head_sha]
done = [r for r in head_runs if r.get("status") == "completed"]
if not done:
    print("PENDING|%s|" % head_sha[:8]); sys.exit(0)
fails = [r["name"] for r in done if r.get("conclusion") == "failure"]
if fails:
    print("FAIL|%s|%s" % (head_sha[:8], ",".join(sorted(set(fails)))[:120])); sys.exit(0)
print("PASS|%s|" % head_sha[:8])
'

# Latest CI-style workflow conclusion on main. Delivery gates only; ignores scheduled
# monitors (Runner health check) + workflow_run children so a transient runner-probe
# red doesn't masquerade as code breakage.
latest_main_conclusion() {
  local slug="$1"
  _ut "$OS_UT_FAST" gh run list --repo "$GH_USER/$slug" --branch main --limit 25 \
    --json name,conclusion,status,event,headSha,createdAt 2>/dev/null \
  | python3 -c "$_PY_MAIN_CI" 2>/dev/null
}

probe_repo_ci() {
  local slug="$1"
  local res; res="$(latest_main_conclusion "$slug")"
  local verdict sha detail
  IFS='|' read -r verdict sha detail <<<"$res"
  verdict="${verdict:-UNKNOWN}"

  local statefile="$STATE_DIR/${slug}.main-ci"
  local prev=""; [ -f "$statefile" ] && prev="$(cat "$statefile" 2>/dev/null)"

  case "$verdict" in
    FAIL)
      if [ "$prev" = "PASS" ]; then
        anomaly "🔴 $slug: main CI was GREEN, now FAILING @ $sha — regression. Failed: ${detail:-?}"
      else
        note "$slug: main CI failing @ $sha — ${detail:-?}"
      fi
      echo "FAIL" > "$statefile" 2>/dev/null || true
      ;;
    PASS)
      echo "PASS" > "$statefile" 2>/dev/null || true
      ;;
    PENDING|NONE|UNKNOWN)
      : # don't overwrite a known-good/bad state on an inconclusive read
      ;;
  esac
}

# Reduce `gh pr list` JSON on stdin to one line per open PR with hard-failing checks.
# slug arrives via argv[1]; program off -c so stdin stays the gh data (see _PY_MAIN_CI).
_PY_PRS='
import sys, json
slug = sys.argv[1]
try:
    prs = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for pr in prs:
    if pr.get("isDraft"):
        continue
    roll = pr.get("statusCheckRollup") or []
    # a check is a hard fail only on FAILURE/TIMED_OUT/STARTUP_FAILURE (cancelled = infra)
    failed = [c for c in roll
              if c.get("conclusion") in ("FAILURE", "TIMED_OUT", "STARTUP_FAILURE")]
    if failed:
        names = ",".join(sorted({c.get("name", "?") for c in failed}))[:100]
        print("%s PR#%s red: %s" % (slug, pr["number"], names))
'

probe_repo_prs() {
  local slug="$1"
  _ut "$OS_UT_FAST" gh pr list --repo "$GH_USER/$slug" --state open --limit 20 \
     --json number,title,statusCheckRollup,isDraft 2>/dev/null \
  | python3 -c "$_PY_PRS" "$slug" 2>/dev/null
}

probe_runners() {
  # Runners are native Mac runners registered at ORG level (Umbra retired 2026-11-14), so the
  # repo-scoped API cannot see them: enumerate the org's runners once and flag any not online.
  # The org-wide verdict (all offline / a whole label pool offline) is ci-runner-guard's job.
  local slug="$1" offline
  [ -z "${_RUNNERS_PROBED:-}" ] || return 0
  _RUNNERS_PROBED=1   # global (not local): one org-level probe per run, not one per repo
  offline=$(_ut "$OS_UT_FAST" gh api "orgs/$GH_USER/actions/runners?per_page=100" \
       --jq '[.runners[]|select(.status!="online")|"\(.name)=\(.status)"]|join(", ")' 2>/dev/null) || return
  [ -n "$offline" ] || return
  note "$GH_USER: self-hosted Mac runner(s) offline ($offline). Check the launchd services: launchctl list | grep actions.runner.$GH_USER (restart: launchctl kickstart -k gui/\$(id -u)/actions.runner.$GH_USER.<name>)."
}

for slug in ${REPOS[@]+"${REPOS[@]}"}; do
  probe_repo_ci "$slug"
  while IFS= read -r line; do [ -n "$line" ] && note "$line"; done < <(probe_repo_prs "$slug")
done
for slug in "${SELFHOSTED_REPOS[@]}"; do
  probe_runners "$slug"
done

total=$(( ${#findings[@]} + ${#anomalies[@]} ))
if [ "$total" -eq 0 ]; then
  echo "os-watch: all repos green ($(date '+%H:%M'))"
  exit 0
fi

body=""
[ ${#anomalies[@]} -gt 0 ] && body+="$(printf '%s\n' ${anomalies[@]+"${anomalies[@]}"})"$'\n'
[ ${#findings[@]} -gt 0 ]  && body+="$(printf '%s\n' ${findings[@]+"${findings[@]}"})"

if [ -x "$NOTIFY" ]; then
  printf '%s' "$body" | "$NOTIFY" "Delivery watch — ${total} issue(s)"
else
  echo "os-watch findings (notify.sh missing):"; printf '%s\n' "$body"
fi
