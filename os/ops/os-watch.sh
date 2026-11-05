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
# Fleet park state — see lib/runner-fleet.sh. FAIL CLOSED: no lib => not parked,
# so a missing file can never silence a real runner outage.
. "$HERE/lib/runner-fleet.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/runner-fleet.sh" 2>/dev/null || true
command -v fleet_parked >/dev/null 2>&1 || { fleet_parked() { return 1; }; fleet_park_reason() { printf 'unknown'; }; }

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
  # Don't hardcode runner names (the old windows-wsl-fwb* list went stale when the
  # runners moved hosts and this probe silently checked nothing for weeks) —
  # enumerate whatever is registered and flag any not-online. (Runner host is now
  # the Umbra VM $OS_VM; OrbStack was retired 2026-07.)
  local slug="$1"
  # Fleet parked (2026-08-09) => a runner being offline is the INTENDED state, not
  # a fault. Without this, os-watch both notes the "outage" AND fires
  # ci-runner-guard at it, which is how a deliberately out-of-service runner kept
  # paging every cycle. ci-runner-guard still asserts the safety invariant while
  # parked (every repo on cloud), so standing down here is not standing down blind.
  if fleet_parked; then
    note "$slug: self-hosted runners offline — EXPECTED, fleet is parked ($(fleet_park_reason)). Un-park: rm $FLEET_PARK_FILE"
    return
  fi
  local offline
  offline=$(_ut "$OS_UT_FAST" gh api "repos/$GH_USER/$slug/actions/runners" \
       --jq '[.runners[]|select(.status!="online")|"\(.name)=\(.status)"]|join(", ")' 2>/dev/null) || return
  [ -n "$offline" ] || return
  # G6 (2026-07-22): don't just ALERT — trigger the heal now. os-watch runs on a
  # slow (2h) cadence, so waiting for ci-runner-guard's own 30-min cycle leaves the
  # VM down in between (the incident that produced the OrbStack-worded alert).
  # ci-runner-guard is idempotent + self-coordinating (wr_claim), so firing it on
  # detection is safe; guard with _RUNNER_HEAL_FIRED so we kick it once per run.
  local trg=""
  if [ -z "${_RUNNER_HEAL_FIRED:-}" ] && [ -x "$HOME/.claude/scripts/ci-runner-guard.sh" ]; then
    _RUNNER_HEAL_FIRED=1   # global (not local) — persists across repos in this run
    nohup "$HOME/.claude/scripts/ci-runner-guard.sh" >/dev/null 2>&1 &
    trg=" — auto-heal TRIGGERED (ci-runner-guard boots the stopped Umbra VM)"
  fi
  note "$slug: self-hosted runner(s) offline ($offline)$trg. If it persists, run 'umbra start $OS_VM' and check 'umbra shell $OS_VM -- systemctl status actions.runner.*'."
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
