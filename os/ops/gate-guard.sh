#!/usr/bin/env bash
# gate-guard.sh — Whisky AI OS closed-loop gate keeper (self-heal actor).
#
# Gap it closes (2026-07-10): the "AI Review" gate sat `disabled_manually` for 25
# days and the self-healing OS never noticed — the OS watched for CI *failures* but
# not for its own *gates being silently turned off*. A disabled gate is invisible
# to failure-based monitors (it just stops producing signal). This is the missing
# feedback edge that makes the loop CLOSED: keep the gates themselves alive.
#
# What it does, per Force repo:
#   1. Detect any CRITICAL gate workflow that is NOT `active` (disabled_manually etc.)
#      — excluding an allowlist of intentionally-disabled ones (managed Postgres snapshot = retired
#      for cost; ZAP = opt-in).
#   2. AUTO RE-ENABLE it (`gh workflow enable`) — self-healing, not just alerting.
#   3. Flag active gates that haven't RUN in >STALE_DAYS — but only after asking
#      whether the gate COULD have run: a deleted workflow file, a manual-only
#      trigger, or a repo with no push since the last run are not stale gates.
#      Names in NOT_A_GATE (e.g. the `Reusable CI` library this repo publishes for
#      other repos to `uses:`) are excluded entirely — they gate nothing here.
#   4. Fire ONE Telegram digest via notify.sh describing what it found + did.
#      Deleted-file findings are deduped via a ledger so a durable, known state
#      does not re-alert every 6h.
#
# Guardrails: fail-open (never throws), DRY_RUN=1 to simulate, full audit log,
# allowlist so it never fights a deliberate disable.
#
# Usage: gate-guard.sh            (act + alert)
#        DRY_RUN=1 gate-guard.sh  (detect + log only, no mutation, no alert)
# shellcheck source=lib/os-config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/os-config.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-config.sh" 2>/dev/null || true
command -v os_config_load >/dev/null 2>&1 && os_config_load
set -uo pipefail

# _ut (hard wall clock on external calls) lives in the shared lib — without this
# source every _ut call below would be a "command not found", i.e. the guard
# would fail silently instead of bounding anything.
. "$(dirname "$0")/lib/os-state.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-state.sh" 2>/dev/null || true

export PATH="/opt/homebrew/bin:/usr/bin:/bin:$PATH"

HERE="$HOME/.claude/scripts"
NOTIFY="$HERE/notify.sh"
STATE="$HOME/.whisky-os-state"
LOG="$STATE/gate-guard.log"
mkdir -p "$STATE"
DRY="${DRY_RUN:-0}"
STALE_DAYS="${GATE_STALE_DAYS:-21}"

# Repos to guard — AUTO-DISCOVER every non-archived repo across the Force + Whisky 11 orgs +
# Ahmad's personal account, so new repos are covered the moment they exist (no
# hardcoded list to drift). Repos without any CI gate workflow simply match
# nothing below and are skipped. Override with GATE_REPOS="owner/a owner/b".
GATE_OWNERS="${GATE_OWNERS:-$OS_ORGS}"  # keep in sync with runner-focus.sh + runner-reregister.sh
_discover_repos(){
  local o
  for o in $GATE_OWNERS; do
    _ut "$OS_UT_FAST" gh repo list "$o" --limit 500 --no-archived --json nameWithOwner -q '.[].nameWithOwner' 2>/dev/null
  done
}
REPOS="${GATE_REPOS:-$(_discover_repos)}"
# Critical gate workflows that MUST stay enabled (display-name regex, case-insensitive).
CRITICAL="${GATE_CRITICAL:-\\bci\\b|ai review|blast-radius|gitleaks|semgrep|scoped audit|runner health|auto-fix}"
# Names that LOOK like a gate but are not one for the repo they live in. `Reusable CI`
# is `on: workflow_call` — a LIBRARY this repo publishes for other repos to call via
# `uses:`. It gates nothing here and can never run here, so matching it on `\bci\b`
# only ever produced a false "never run" finding. This is a precision fix, not a mute:
# the workflows it is called FROM are still graded in their own repos.
NOT_A_GATE="${GATE_NOT_A_GATE:-reusable ci}"
# Intentionally-disabled — never auto-enable these (cost / opt-in). Per-commit database
# snapshots are retired (local pg_dump replaced them).
ALLOW_DISABLED="${GATE_ALLOW_DISABLED:-zap}"

ts(){ date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo now; }
log(){ printf '%s %s\n' "$(ts)" "$*" >>"$LOG"; }
command -v gh >/dev/null 2>&1 || { log "gh not found — skip"; exit 0; }

ACC="$(mktemp)"; trap 'rm -f "$ACC"' EXIT

for repo in $REPOS; do
  short="${repo##*/}"
  # `path` is required by the staleness classifier below (deleted-file and
  # no-automatic-trigger checks). Without it every classifier silently no-ops and
  # the guard falls back to blanket "stale" alerts.
  json="$(_ut "$OS_UT_FAST" gh workflow list -R "$repo" --all --json name,state,id,path 2>/dev/null)" || { log "$repo: workflow list failed"; continue; }
  [ -n "$json" ] || continue

  # Disabled critical gates (excluding allowlist) → emit "id\tname\tstate".
  printf '%s' "$json" | CRIT="$CRITICAL" ALLOW="$ALLOW_DISABLED" NOTGATE="$NOT_A_GATE" python3 -c '
import json,sys,re,os
crit=re.compile(os.environ["CRIT"],re.I); allow=re.compile(os.environ["ALLOW"],re.I)
notgate=re.compile(os.environ.get("NOTGATE") or r"(?!x)x",re.I)
try: data=json.load(sys.stdin)
except Exception: sys.exit(0)
for w in data:
    n=w.get("name",""); s=w.get("state","")
    if crit.search(n) and not allow.search(n) and not notgate.search(n) and s!="active":
        print("%s\t%s\t%s"%(w.get("id",""),n,s))
' | while IFS=$'\t' read -r wid wname wstate; do
    [ -n "$wid" ] || continue
    if [ "$DRY" = "1" ]; then act="(dry-run — would re-enable)"
    else gh workflow enable "$wid" -R "$repo" >/dev/null 2>&1 && act="→ re-enabled ✅" || act="→ RE-ENABLE FAILED ❌"; fi
    log "$repo: gate '$wname' was $wstate $act"
    printf '• %s: "%s" was %s %s\n' "$short" "$wname" "$wstate" "$act" >>"$ACC"
  done

  # Staleness: active critical gates whose most-recent run is older than STALE_DAYS.
  printf '%s' "$json" | CRIT="$CRITICAL" ALLOW="$ALLOW_DISABLED" NOTGATE="$NOT_A_GATE" python3 -c '
import json,sys,re,os
crit=re.compile(os.environ["CRIT"],re.I); allow=re.compile(os.environ["ALLOW"],re.I)
notgate=re.compile(os.environ.get("NOTGATE") or r"(?!x)x",re.I)
try: data=json.load(sys.stdin)
except Exception: sys.exit(0)
for w in data:
    n=w.get("name",""); s=w.get("state","")
    if crit.search(n) and not allow.search(n) and not notgate.search(n) and s=="active":
        print("%s\t%s" % (n, w.get("path","")))
' | while IFS=$'\t' read -r wname wpath; do
    [ -n "$wname" ] || continue
    last="$(_ut "$OS_UT_FAST" gh run list -R "$repo" --workflow "$wname" -L 1 --json createdAt -q '.[0].createdAt' 2>/dev/null)"
    # NEVER-RUN is the strongest staleness signal, not an absence of signal.
    # This used to `continue`, which made the guard fail OPEN: a workflow that
    # can never be triggered (e.g. `on: workflow_call` only) is `active`, matches
    # the critical-gate regex by NAME, and has zero runs — so it was silently
    # skipped and the repo reported healthy. That is exactly how
    # ebda-foundation ran with no CI at all while gate-guard stayed quiet
    # (found 2026-08-16; the repo's own `ci.yml` lands in the same PR).
    if [ -z "$last" ]; then
      log "$repo: gate '$wname' active but has NEVER run — cannot be triggered?"
      printf '• %s: "%s" enabled but has NEVER RUN — check its `on:` triggers 🚨\n' "$short" "$wname" >>"$ACC"
      continue
    fi
    lastEpoch="$(date -j -f '%Y-%m-%dT%H:%M:%SZ' "$last" '+%s' 2>/dev/null || echo 0)"
    [ "$lastEpoch" -gt 0 ] 2>/dev/null || continue
    ageDays=$(( ( $(date '+%s') - lastEpoch ) / 86400 ))
    [ "$ageDays" -gt "$STALE_DAYS" ] || continue

    # "Hasn't run lately" is only a PROBLEM if the gate could have run and didn't.
    # Blanket-flagging produced 4 alerts on 2026-08-16, and every one was noise:
    #   store 'Runner health check'  — schedule deliberately commented out, only
    #                                workflow_dispatch left (documented in-file)
    #   umbra 'umbra-ci verify'    — workflow FILE DELETED; only the lingering
    #                                Actions record remains, still state=active
    #   ci-runner-verify           — on: push, but the repo has had no push since
    #   example-media gitleaks        — repo idle since its last run
    # Alert fatigue is how a real dead gate gets ignored, so classify instead.
    # (a) The workflow file is gone from the default branch — GitHub keeps the
    #     Actions record forever. That is a DELETED gate, not a stale one.
    if [ -n "$wpath" ] && ! _ut "$OS_UT_FAST" gh api "repos/$repo/contents/$wpath" >/dev/null 2>&1; then
      # Report ONCE per (repo, workflow). A deleted workflow file is a durable
      # state — GitHub keeps the Actions record indefinitely — so re-alerting every
      # 6h is pure noise for a condition the human already knows about and must
      # clear on GitHub's side. Still logged every run; only the Telegram digest
      # is deduped. Delete the ledger line to re-surface it.
      ledger="$STATE/gate-guard-deleted.seen"
      key="$repo|$wname"
      log "$repo: gate '$wname' listed active but its file ($wpath) no longer exists"
      if ! grep -qxF "$key" "$ledger" 2>/dev/null; then
        printf '• %s: "%s" is listed active but its workflow FILE IS DELETED (%s) — clear the Actions record 🧹\n' "$short" "$wname" "$wpath" >>"$ACC"
        [ "$DRY" = "1" ] || printf '%s\n' "$key" >>"$ledger"
      fi
      continue
    fi

    # (b) No automatic trigger (workflow_dispatch / workflow_call only) — it can
    #     only run when a human or another workflow fires it, so recency is
    #     meaningless. Never-run is still reported above; this only mutes age.
    if [ -n "$wpath" ]; then
      # `[[:space:]]` not `\s` — BSD grep -E has no \s. Comment lines are stripped
      # first so a commented-out `# schedule:` does not read as a live trigger
      # (store's runner-health-check is exactly that case).
      trig="$(_ut "$OS_UT_FAST" gh api "repos/$repo/contents/$wpath" --jq '.content' 2>/dev/null \
        | base64 -d 2>/dev/null | sed -n '/^on:/,/^[a-zA-Z]/p' | sed 's/#.*$//' \
        | grep -cE '^[[:space:]]*(push|pull_request|schedule|release|issue_comment):' || true)"
      if [ "${trig:-0}" = "0" ]; then
        log "$repo: gate '$wname' ${ageDays}d idle but has no automatic trigger — not stale"
        continue
      fi
    fi

    # (c) The repo itself has had no push since the gate last ran — a quiet repo,
    #     not a broken gate.
    pushedAt="$(_ut "$OS_UT_FAST" gh api "repos/$repo" --jq '.pushed_at' 2>/dev/null)"
    pushEpoch="$(date -j -f '%Y-%m-%dT%H:%M:%SZ' "$pushedAt" '+%s' 2>/dev/null || echo 0)"
    if [ "$pushEpoch" -gt 0 ] 2>/dev/null && [ "$pushEpoch" -le "$lastEpoch" ]; then
      log "$repo: gate '$wname' ${ageDays}d idle but repo has had no push since — not stale"
      continue
    fi

    log "$repo: gate '$wname' active but last run ${ageDays}d ago (stale)"
    printf '• %s: "%s" enabled but has not run in %sd ⚠️\n' "$short" "$wname" "$ageDays" >>"$ACC"
  done
done

if [ -s "$ACC" ]; then
  if [ "$DRY" != "1" ]; then
    { echo "Gate-guard swept Force CI gates and found issues:"; echo; cat "$ACC"; } | "$NOTIFY" "🚧 OS gate-guard" >/dev/null 2>&1 || true
    log "alerted ($(wc -l <"$ACC" | tr -d ' ') item(s))"
  else
    log "dry-run: would alert ($(wc -l <"$ACC" | tr -d ' ') item(s)) — no notify"
  fi
else
  log "all critical gates active + fresh across: $REPOS"
fi
