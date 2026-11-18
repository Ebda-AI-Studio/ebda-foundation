#!/usr/bin/env bash
# Ebda AI OS — main-first CI.
#
# Problem (measured 3x on 2026-11-14): the main-branch CI run of ebda-store sat `queued` for hours because the
# self-hosted heavy runners (labels self-hosted + ebda-mac) were taken by pull_request runs; GitHub does not
# schedule self-hosted jobs FIFO across runs. While main CI is not green the merge drain only merges fixes-main PRs,
# so every other approved PR stalls. This script does by machine what the controller did by hand.
#
# Per repo in $MAIN_FIRST_REPOS, if the NEWEST main CI run is queued/in_progress AND any of its jobs has been
# queued longer than $MAIN_FIRST_MIN minutes (default 10):
#   1. cancel OLDER main CI runs whose head is an ancestor of the newest main head (superseded);
#   2. cancel QUEUED pull_request runs holding a queued job that asks for the heavy label ($MAIN_FIRST_LABEL,
#      default ebda-mac) - never in_progress runs, never a branch in $MAIN_FIRST_ALLOW_BRANCHES or a PR labelled
#      $MAIN_FIRST_ALLOW_LABEL (default fixes-main); one PR comment per head;
#   3. once the newest main CI run completes `success`, re-run the cancelled PR runs once (approved PRs first,
#      oldest approval first), at most $MAIN_FIRST_RERUN_CAP (default 2) per tick; a run whose PR closed or whose head
#      moved (a push already started a fresh run) is dropped, not re-run. Entries expire after 24 h.
# Every GitHub read is gathered BEFORE any mutation; an API failure (5xx/504/bad JSON) skips that repo for this tick.
# Idempotent: state is $MAIN_FIRST_STATE (cancelled-run ledger + commented heads). --dry-run mutates nothing.
# Log: ~/Library/Logs/ebda-main-first.log. Exit 0 always except usage errors (2).
#
# BATCH-FIRST (2026-11-15): ebda-store PR CI is ~15 heavy jobs per PR on 2 heavy runners and GitHub serves FIFO, so
# the PRs the merge drain gates next wait behind PRs that will not merge soon. The drain (script lives OUTSIDE this
# repo) writes the batch file; main-first only READS it.
#   Contract: file `$STATE/drain-batch-<owner>__<repo>` (default STATE ~/.whisky-os-state/main-first, e.g.
#   ~/.whisky-os-state/main-first/Ebda-AI-Studio__ebda-store; override: MAIN_FIRST_BATCH_FILE), plain text, one PR
#   number per line, the PRs the drain will gate next (first $MAIN_FIRST_BATCH_MAX=3 lines used; non-numeric ignored).
#   The writer rewrites it (touch) every drain tick; mtime older than $MAIN_FIRST_BATCH_MAX_AGE_MIN (default 15) or a
#   missing/empty file = feature OFF (today's behaviour; logged once per transition).
#   When main's newest CI run is green and the file is fresh: QUEUED pull_request runs whose head branch is not a
#   batch PR's head (and not main / allowlisted / fixes-main) are cancelled, but only if EVERY job of the run is
#   still queued (a run with any in_progress/completed job is left alone). push/schedule runs are never touched.
#   Cancelled runs go to the ledger. Re-run order while a batch is fresh: batch PRs first (oldest approval first),
#   non-batch entries are HELD (re-running them would only be re-cancelled next tick) until the batch file goes
#   stale or no longer lists the batch; with no fresh batch the order is the plain oldest-approval order.
# MAIN LEASE (Ruling MAIN-LEASE-1, 2026-11-17): the 5-minute tick above cancels the PR runs that are queued AT THE TICK, but GitHub hands queued
# jobs to runners NEWEST-first, so a PR queue that refills between ticks keeps winning and main CI starved twice in one day (61 min queued, 54
# approved PRs blocked). While a repo's newest main CI run has a QUEUED job (queued longer than $MAIN_FIRST_LEASE_MIN_QUEUED_S, default 30, so a
# job that starts at once costs nothing) main holds a LEASE: after the normal pass the tick keeps running a short loop ($MAIN_FIRST_LEASE_TICK s,
# default 30, for at most $MAIN_FIRST_LEASE_BUDGET s, default 270, inside the 5-minute launchd interval) that cancels every NEWLY queued,
# non-protected PR run on arrival (every job still queued, asking for the heavy OR the light label; protected = a batch PR from the drain's batch file, a
# fixes-main PR, an allow-listed branch, main/push/schedule runs), logging each to the lease ledger. The lease is released the moment main has
# no queued job left for TWO steps in a row (main queues in waves: `needs:`), or main completed, or the run is gone: the logged runs are re-run
# and each re-run is CONFIRMED (queued / in progress / higher attempt); a run still cancelling or whose re-run did not take stays in the lease ledger
# and is retried each step (5 steps, then LEASE-RERUN-FAILED); a run the lease already re-ran for this main run is never cancelled again. Both pools
# count: a queued main job on ebda-mac, ebda-mac-light or ebda-mac-any ($MAIN_FIRST_LEASE_LABELS) takes the lease and PR runs queued on either are cancelled.
# (PR open, head unchanged, still cancelled are checked before a re-run; a fresh drain batch hands non-batch runs to the normal ledger.) A repo whose main has no queued job never takes a lease. MAIN_FIRST_LEASE=0 turns it off.
# CROSS-REPO FAIRNESS (G16, 2026-11-15): the heavy runners are an ORG pool shared by ebda-store, ebda-whatsapp and ebda-foundation, but
# the rules above only cancel the STARVED repo's own PR runs, so one repo's PR backlog could hold the pool while another repo's main CI
# starved (its own queue had nothing left to cancel). Main-before-PR stays rule one; after a starved repo's own PR runs are cancelled,
# the OTHER repos' queued PR runs (heavy label, EVERY job still queued, not main / allowlisted / fixes-main) are cancelled too, but
#   - round-robin by repo: one run per repo per round (newest-queued first, so the longest-waiting keep their place), at most
#     $MAIN_FIRST_FAIR_CAP (default 3) per repo and $MAIN_FIRST_FAIR_TOTAL (default 6) overall per starved repo per tick, so no single
#     repo pays for another's starvation alone;
#   - the repo processing order rotates every tick ($STATE/rr-cursor), so with a shared budget no repo is always first or last;
#   - each cancelled run goes into ITS OWN repo's ledger and is re-requested by that repo's tick once that repo's main CI is green.
# Seams: gh from PATH, MAIN_FIRST_{FAIR_CAP,FAIR_TOTAL}, MAIN_FIRST_{BATCH_FILE,BATCH_MAX,BATCH_MAX_AGE_MIN}, MAIN_FIRST_{REPOS (default: $OS_ORG + os_local_list main_first_repos),MIN,LABEL,ALLOW_BRANCHES,ALLOW_LABEL,RERUN_CAP,WORKFLOW,STATE,LOG,NOW}.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/os-state.sh
. "$HERE/lib/os-state.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-state.sh" 2>/dev/null || true
command -v _ut >/dev/null 2>&1 || _ut() { shift; "$@"; }
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"

DRY=0
case "${1:-}" in
  --dry-run) DRY=1 ;;
  -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
  '') ;;
  *) echo "main-first: unknown arg $1 (only --dry-run)" >&2; exit 2 ;;
esac

# shellcheck source=lib/os-config.sh
. "$HERE/lib/os-config.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-config.sh" 2>/dev/null || true
command -v os_config_load >/dev/null 2>&1 && os_config_load
if [ -z "${MAIN_FIRST_REPOS:-}" ]; then
  MAIN_FIRST_REPOS=""
  # repo names (key main_first_repos in ~/.ebda-os.local.json, defaults below) under the primary org $OS_ORG
  while IFS= read -r _r; do [ -n "$_r" ] && MAIN_FIRST_REPOS="${MAIN_FIRST_REPOS:+$MAIN_FIRST_REPOS }${OS_ORG:?main-first: OS_ORG unset}/$_r"; done \
    < <(os_local_list main_first_repos ebda-store ebda-whatsapp ebda-foundation 2>/dev/null)
fi
REPOS="$MAIN_FIRST_REPOS"
MIN="${MAIN_FIRST_MIN:-10}"
LABEL="${MAIN_FIRST_LABEL:-ebda-mac}"
ALLOW_BRANCHES="${MAIN_FIRST_ALLOW_BRANCHES:-}"
ALLOW_LABEL="${MAIN_FIRST_ALLOW_LABEL:-fixes-main}"
CAP="${MAIN_FIRST_RERUN_CAP:-2}"
WORKFLOW="${MAIN_FIRST_WORKFLOW:-CI}"
STATE="${MAIN_FIRST_STATE:-$HOME/.whisky-os-state/main-first}"
LOG="${MAIN_FIRST_LOG:-$HOME/Library/Logs/ebda-main-first.log}"
NOW="${MAIN_FIRST_NOW:-$(date +%s)}"
BATCH_MAX="${MAIN_FIRST_BATCH_MAX:-3}"
BATCH_AGE="${MAIN_FIRST_BATCH_MAX_AGE_MIN:-15}"
GH_TIMEOUT="${GH_TIMEOUT:-45}"
FAIR_CAP="${MAIN_FIRST_FAIR_CAP:-3}"; FAIR_TOTAL="${MAIN_FIRST_FAIR_TOTAL:-6}"
LEASE="${MAIN_FIRST_LEASE:-1}"; LEASE_TICK="${MAIN_FIRST_LEASE_TICK:-30}"; LEASE_BUDGET="${MAIN_FIRST_LEASE_BUDGET:-270}"
LEASE_MIN_Q="${MAIN_FIRST_LEASE_MIN_QUEUED_S:-30}"; LEASE_CAP="${MAIN_FIRST_LEASE_RERUN_CAP:-10}"
LEASE_LABELS="${MAIN_FIRST_LEASE_LABELS:-$LABEL ${MAIN_FIRST_LIGHT_LABEL:-ebda-mac-light} ${MAIN_FIRST_ANY_LABEL:-ebda-mac-any}}"   # RUNNER-ANY-1: the shared pool label on all four runners
for v in MIN CAP BATCH_MAX BATCH_AGE FAIR_CAP FAIR_TOTAL LEASE LEASE_TICK LEASE_BUDGET LEASE_MIN_Q LEASE_CAP; do case "${!v}" in ''|*[!0-9]*) echo "main-first: $v must be a whole number" >&2; exit 2 ;; esac; done
mkdir -p "$STATE" "$(dirname "$LOG")" 2>/dev/null || true

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG"; }

# one run at a time (launchd tick vs a manual run); a lock older than 10 min is dead
LOCK="$STATE/lock.d"
if ! mkdir "$LOCK" 2>/dev/null; then
  if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then rmdir "$LOCK" 2>/dev/null; mkdir "$LOCK" 2>/dev/null || exit 0
  else log "skip: another main-first run holds the lock"; exit 0; fi
fi
FAIR_DIR="$(mktemp -d 2>/dev/null || echo "$STATE/fair.$$")"; mkdir -p "$FAIR_DIR"
trap 'rmdir "$LOCK" 2>/dev/null; rm -rf "$FAIR_DIR"' EXIT

# gh GET -> stdout; non-zero on any failure (5xx/504/timeout) or non-JSON body
api() {
  local out
  out="$(_ut "$GH_TIMEOUT" gh api "$@" 2>/dev/null)" || return 1
  printf '%s' "$out" | python3 -c 'import sys,json; json.load(sys.stdin)' 2>/dev/null || return 1
  printf '%s' "$out"
}
# mutation wrapper: honours --dry-run
act() { # <description> <gh args...>
  local desc="$1"; shift
  if [ "$DRY" = 1 ]; then log "DRYRUN would $desc"; return 0; fi
  if _ut "$GH_TIMEOUT" gh api "$@" >/dev/null 2>&1; then log "$desc"; return 0; fi
  log "FAILED $desc"; return 1
}
# cancel a run; GitHub often leaves a cancelled QUEUED self-hosted run queued, so re-read after
# $MAIN_FIRST_VERIFY_WAIT s (default 20) and escalate to force-cancel when it is still queued.
cancel_run() { # <repo> <run id> <description>
  local repo="$1" id="$2" desc="$3" st
  act "$desc" -X POST "repos/$repo/actions/runs/$id/cancel" || return 1
  [ "$DRY" = 1 ] && return 0
  sleep "${MAIN_FIRST_VERIFY_WAIT:-20}"
  st="$(api "repos/$repo/actions/runs/$id" | py 'print(d.get("status",""))')" || st=""
  case "$st" in
    queued) log "$repo: run $id still queued after cancel; escalating"
            act "force-cancel run $id ($repo)" -X POST "repos/$repo/actions/runs/$id/force-cancel" || true ;;
    '')     log "$repo: could not re-read run $id after cancel; no force-cancel this tick" ;;
  esac
  return 0
}
# jq-ish helper: py '<expr over d>' reads JSON on stdin
py() { python3 -c 'import sys,json; d=json.load(sys.stdin); '"$1" 2>/dev/null; }

# batch-first: sets BATCH_PRS (space separated, max BATCH_MAX) when the drain's batch file is fresh, else ""
load_batch() { # <repo slug>
  local slug="$1" f="${MAIN_FIRST_BATCH_FILE:-$STATE/drain-batch-$1}" mark="$STATE/$1.batch-off" mt age
  BATCH_PRS=""
  if [ ! -s "$f" ]; then
    [ -e "$mark" ] || { log "$slug: no drain batch file ($f); batch-first off"; : > "$mark"; }
    return 0
  fi
  mt="$(python3 -c 'import os,sys; print(int(os.path.getmtime(sys.argv[1])))' "$f" 2>/dev/null)" || mt=0
  age=$((NOW - mt))
  if [ "$age" -gt $((BATCH_AGE * 60)) ]; then
    [ -e "$mark" ] || { log "$slug: drain batch file stale (${age}s > ${BATCH_AGE}m); batch-first off"; : > "$mark"; }
    return 0
  fi
  BATCH_PRS="$(grep -E '^[0-9]+$' "$f" | head -n "$BATCH_MAX" | tr '\n' ' ')"
  BATCH_PRS="${BATCH_PRS% }"
  [ -n "$BATCH_PRS" ] || return 0
  if [ -e "$mark" ]; then rm -f "$mark"; log "$slug: drain batch file fresh again; batch-first on"; fi
}
in_batch() { case " $BATCH_PRS " in *" $1 "*) return 0 ;; esac; return 1; }
# HELD-RERUN-1b: the LAUNCH LIST = the PRs the controller wants through first, one PR number per line in priority order, in
# `$STATE/launch-list-<owner>__<repo>` (override MAIN_FIRST_LAUNCH_FILE; written by the drain/window script from its priority order, same contract style as the
# drain-batch file). A missing, empty or unreadable file = NO list: the idle release then keeps the plain old order (approved first), never a hold.
LAUNCH_PRS=""
load_launch() { # <repo slug>
  local f="${MAIN_FIRST_LAUNCH_FILE:-$STATE/launch-list-$1}"
  LAUNCH_PRS=""
  [ -s "$f" ] || return 0
  LAUNCH_PRS="$(grep -E '^[0-9]+$' "$f" 2>/dev/null | tr '\n' ' ')" || LAUNCH_PRS=""
  LAUNCH_PRS="${LAUNCH_PRS% }"
}
launch_pos() { # <pr> -> 1-based position in the launch list, empty when not on it
  local i=0 x
  for x in $LAUNCH_PRS; do i=$((i + 1)); [ "$x" = "$1" ] && { echo "$i"; return 0; }; done
  return 0
}

# main is green and a fresh batch exists: cancel queued PR runs that are not the batch's
batch_cancel() { # <repo> <ledger>
  local repo="$1" ledger="$2" n pr bbr="" br
  for n in $BATCH_PRS; do
    pr="$(api "repos/$repo/pulls/$n")" || { log "$repo: API failure reading batch PR #$n, no batch cancel this tick"; return 0; }
    br="$(printf '%s' "$pr" | py 'print(d["head"]["ref"])')"
    [ -n "$br" ] && bbr="$bbr $br"
  done
  local prruns; prruns="$(api "repos/$repo/actions/runs?status=queued&event=pull_request&per_page=100")" || { log "$repo: API failure reading queued PR runs, no batch cancel this tick"; return 0; }
  local cand; cand="$(printf '%s' "$prruns" | python3 -c '
import sys,json
d=json.load(sys.stdin)
for x in d["workflow_runs"]:
    if x.get("status")!="queued" or x.get("event","pull_request")!="pull_request" or x.get("head_branch","").startswith("gh-readonly-queue/"): continue   # a merge-queue run is never cancelled (MAIN-FIRST-MG-1)
    prs=x.get("pull_requests") or []
    print(x["id"], x.get("head_branch",""), x.get("head_sha",""), prs[0]["number"] if prs else 0)' 2>/dev/null)" || { log "$repo: bad PR runs JSON, no batch cancel this tick"; return 0; }
  local rid sha prn jobs labels todo=() e rest
  while read -r rid br sha prn; do
    [ -n "$rid" ] || continue
    [ "$br" = main ] && continue
    case " $bbr " in *" $br "*) log "$repo: PR #$prn run $rid is in the drain batch; kept"; continue ;; esac
    case ",$ALLOW_BRANCHES," in *",$br,"*) continue ;; esac
    jobs="$(api "repos/$repo/actions/runs/$rid/jobs?per_page=100")" || { log "$repo: API failure reading jobs of $rid, no batch cancel this tick"; return 0; }
    if ! printf '%s' "$jobs" | python3 -c '
import sys,json
d=json.load(sys.stdin)
sys.exit(0 if all(j.get("status")=="queued" for j in d.get("jobs",[])) else 1)' 2>/dev/null; then
      log "$repo: PR #$prn run $rid already partially started; kept"; continue
    fi
    if [ "$prn" != 0 ]; then
      labels="$(api "repos/$repo/issues/$prn/labels")" || { log "$repo: API failure reading labels of #$prn, no batch cancel this tick"; return 0; }
      if printf '%s' "$labels" | AL="$ALLOW_LABEL" python3 -c '
import sys,json,os
sys.exit(0 if any(l.get("name")==os.environ["AL"] for l in json.load(sys.stdin)) else 1)' 2>/dev/null; then continue; fi
    fi
    todo+=("$rid:$sha:$prn")
  done <<<"$cand"
  for e in "${todo[@]+"${todo[@]}"}"; do
    rid="${e%%:*}"; rest="${e#*:}"; sha="${rest%%:*}"; prn="${rest#*:}"
    if cancel_run "$repo" "$rid" "batch-first: cancel queued PR run $rid ($repo PR #$prn, head $sha): not in drain batch [$BATCH_PRS]"; then
      [ "$DRY" = 1 ] || { cut -f1 "$ledger" | grep -qx "$rid" || printf '%s\t%s\t%s\t%s\n' "$rid" "$prn" "$sha" "$NOW" >> "$ledger"; }
    fi
  done
}

# ---- cross-repo fairness (G16) ----
# fair_gather <starved repo>: for every OTHER repo, list its cancellable queued PR runs into $FAIR_DIR/<slug>.cand (newest first).
# Reads only; a failing repo is skipped (logged), never a reason to skip the starved repo's own actions.
FAIR_REPOS=""
fair_gather() {
  local starved="$1" o oslug prruns cand rid br sha prn created jobs labels
  FAIR_REPOS=""
  for o in $REPOS; do
    [ "$o" = "$starved" ] && continue
    oslug="${o//\//__}"; : > "$FAIR_DIR/$oslug.cand"
    prruns="$(api "repos/$o/actions/runs?status=queued&event=pull_request&per_page=100")" || { log "$o: API failure reading queued PR runs (fairness for $starved), repo skipped"; continue; }
    cand="$(printf '%s' "$prruns" | python3 -c '
import sys,json
d=json.load(sys.stdin)
for x in sorted(d["workflow_runs"], key=lambda x: x.get("created_at",""), reverse=True):
    if x.get("status")!="queued" or x.get("event","pull_request")!="pull_request" or x.get("head_branch","").startswith("gh-readonly-queue/"): continue   # a merge-queue run is never cancelled (MAIN-FIRST-MG-1)
    prs=x.get("pull_requests") or []
    print(x["id"], x.get("head_branch",""), x.get("head_sha",""), prs[0]["number"] if prs else 0, x.get("created_at",""))' 2>/dev/null)" || { log "$o: bad PR runs JSON (fairness), repo skipped"; continue; }
    while read -r rid br sha prn created; do
      [ -n "$rid" ] || continue
      [ "$br" = main ] && continue
      case ",$ALLOW_BRANCHES," in *",$br,"*) continue ;; esac
      jobs="$(api "repos/$o/actions/runs/$rid/jobs?per_page=100")" || { log "$o: API failure reading jobs of $rid (fairness), run kept"; continue; }
      printf '%s' "$jobs" | LABEL="$LABEL" python3 -c '
import sys,json,os
d=json.load(sys.stdin); js=d.get("jobs",[])
sys.exit(0 if js and all(j.get("status")=="queued" for j in js) and any(os.environ["LABEL"] in (j.get("labels") or []) for j in js) else 1)' 2>/dev/null || continue
      if [ "$prn" != 0 ]; then
        labels="$(api "repos/$o/issues/$prn/labels")" || { log "$o: API failure reading labels of #$prn (fairness), run kept"; continue; }
        if printf '%s' "$labels" | AL="$ALLOW_LABEL" python3 -c '
import sys,json,os
sys.exit(0 if any(l.get("name")==os.environ["AL"] for l in json.load(sys.stdin)) else 1)' 2>/dev/null; then continue; fi
      fi
      printf '%s %s %s %s\n' "$rid" "$sha" "$prn" "$br" >> "$FAIR_DIR/$oslug.cand"
    done <<<"$cand"
    FAIR_REPOS="$FAIR_REPOS $o"
  done
}
# fair_apply <starved repo> <starved main run id>: round-robin cancel across the repos fair_gather listed.
fair_apply() {
  local starved="$1" nid="$2" taken=0 progress=1 o oslug n rid sha prn br line ledger commented
  while [ "$progress" = 1 ] && [ "$taken" -lt "$FAIR_TOTAL" ]; do
    progress=0
    for o in $FAIR_REPOS; do
      [ "$taken" -lt "$FAIR_TOTAL" ] || break
      oslug="${o//\//__}"
      n="$(cat "$FAIR_DIR/$oslug.taken" 2>/dev/null || echo 0)"
      [ "$n" -lt "$FAIR_CAP" ] || continue
      line="$(sed -n '1p' "$FAIR_DIR/$oslug.cand" 2>/dev/null)"
      [ -n "$line" ] || continue
      sed -i.bak '1d' "$FAIR_DIR/$oslug.cand" 2>/dev/null; rm -f "$FAIR_DIR/$oslug.cand.bak"
      read -r rid sha prn br <<<"$line"
      progress=1
      ledger="$STATE/$oslug.cancelled.tsv"; commented="$STATE/$oslug.commented"; touch "$ledger" "$commented"
      if cancel_run "$o" "$rid" "fairness: cancel queued PR run $rid ($o PR #$prn, head $sha) so $starved main CI $nid gets a runner"; then
        echo $((n + 1)) > "$FAIR_DIR/$oslug.taken"; taken=$((taken + 1))
        [ "$DRY" = 1 ] || { cut -f1 "$ledger" | grep -qx "$rid" || printf '%s\t%s\t%s\t%s\n' "$rid" "$prn" "$sha" "$NOW" >> "$ledger"; }
        if [ "$prn" != 0 ] && ! grep -qx "$prn:$sha" "$commented"; then
          if act "comment on $o#$prn (head $sha)" -X POST "repos/$o/issues/$prn/comments" -f "body=CI re-run deferred: main CI of $starved is waiting for a heavy runner and this repo shares the runner pool. The OS re-requests this run once this repo's main is green."; then
            [ "$DRY" = 1 ] || echo "$prn:$sha" >> "$commented"
          fi
        fi
      fi
    done
  done
  log "$starved: fairness cancelled $taken queued PR run(s) of other repos"
}

process_repo() {

  local repo="$1" slug; slug="${repo//\//__}"
  local ledger="$STATE/$slug.cancelled.tsv" commented="$STATE/$slug.commented"
  touch "$ledger" "$commented"
  load_batch "$slug"

  # ---- gather (no mutation until everything needed is in hand) ----
  local mains; mains="$(api "repos/$repo/actions/runs?branch=main&event=push&per_page=30")" || { log "$repo: API failure reading main runs, skip tick"; return; }
  local newest
  newest="$(printf '%s' "$mains" | WF="$WORKFLOW" python3 -c '
import sys,json,os
d=json.load(sys.stdin)
r=[x for x in d["workflow_runs"] if x.get("name","").lower()==os.environ["WF"].lower()]
r.sort(key=lambda x:x.get("created_at",""),reverse=True)
print(json.dumps(r[0]) if r else "")' 2>/dev/null)" || { log "$repo: bad main runs JSON, skip tick"; return; }
  [ -n "$newest" ] || { log "$repo: no main $WORKFLOW run found"; return; }
  local nid nsha nstatus nconc
  nid="$(printf '%s' "$newest" | py 'print(d["id"])')"; nsha="$(printf '%s' "$newest" | py 'print(d["head_sha"])')"
  nstatus="$(printf '%s' "$newest" | py 'print(d["status"])')"; nconc="$(printf '%s' "$newest" | py 'print(d.get("conclusion") or "")')"
  [ -n "$nid" ] && [ -n "$nsha" ] || { log "$repo: unparsable newest main run, skip tick"; return; }

  # ---- phase 3: main completed green -> re-request cancelled PR runs ----
  if [ "$nstatus" = "completed" ]; then
    log "$repo: newest main $WORKFLOW run $nid ($nsha) completed ${nconc:-unknown}"
    if [ "$nconc" = "success" ] && [ -n "$BATCH_PRS" ]; then batch_cancel "$repo" "$ledger"; fi
    if [ "$nconc" = "success" ]; then rerun_cancelled "$repo" "$ledger" "$nid"; else log "$repo: newest main run $nid completed $nconc; nothing re-run"; fi
    return
  fi
  [ "$nstatus" = "queued" ] || [ "$nstatus" = "in_progress" ] || { log "$repo: newest main run $nid is $nstatus; no action"; return; }

  # ---- is main starved? any job of the newest run queued > MIN minutes ----
  local njobs; njobs="$(api "repos/$repo/actions/runs/$nid/jobs?per_page=100")" || { log "$repo: API failure reading jobs of $nid, skip tick"; return; }
  local starved
  starved="$(printf '%s' "$njobs" | NOW="$NOW" MIN="$MIN" python3 -c '
import sys,json,os,datetime
d=json.load(sys.stdin); now=int(os.environ["NOW"]); lim=int(os.environ["MIN"])*60
def ep(s): return int(datetime.datetime.strptime(s,"%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc).timestamp())
ages=[now-ep(j["created_at"]) for j in d.get("jobs",[]) if j.get("status")=="queued"]
m=max(ages) if ages else 0
print(m//60 if m>lim else "")' 2>/dev/null)" || { log "$repo: bad jobs JSON, skip tick"; return; }
  [ -n "$starved" ] || { log "$repo: main run $nid not starved (no job queued > ${MIN}m); no action"; return; }
  log "$repo: main run $nid ($nsha) has a job queued ~${starved}m > ${MIN}m: acting"

  # superseded main runs
  local older; older="$(printf '%s' "$mains" | WF="$WORKFLOW" NID="$nid" python3 -c '
import sys,json,os
d=json.load(sys.stdin)
for x in d["workflow_runs"]:
    if x.get("name","").lower()==os.environ["WF"].lower() and str(x["id"])!=os.environ["NID"] and x.get("status") in ("queued","in_progress"):
        print(x["id"],x["head_sha"])' 2>/dev/null)" || { log "$repo: bad main runs JSON, skip tick"; return; }
  local to_cancel_main=() oid osha cmp
  while read -r oid osha; do
    [ -n "$oid" ] || continue
    cmp="$(api "repos/$repo/compare/$osha...$nsha")" || { log "$repo: API failure on compare $osha...$nsha, skip tick"; return; }
    case "$(printf '%s' "$cmp" | py 'print(d.get("status",""))')" in
      ahead|identical) to_cancel_main+=("$oid:$osha") ;;
      *) log "$repo: main run $oid ($osha) is not an ancestor of $nsha; kept" ;;
    esac
  done <<<"$older"

  # queued PR runs asking for the heavy label
  local prruns; prruns="$(api "repos/$repo/actions/runs?status=queued&event=pull_request&per_page=100")" || { log "$repo: API failure reading queued PR runs, skip tick"; return; }
  local cand; cand="$(printf '%s' "$prruns" | python3 -c '
import sys,json
d=json.load(sys.stdin)
for x in d["workflow_runs"]:
    if x.get("status")!="queued" or x.get("event","pull_request")!="pull_request" or x.get("head_branch","").startswith("gh-readonly-queue/"): continue   # a merge-queue run is never cancelled (MAIN-FIRST-MG-1)
    prs=x.get("pull_requests") or []
    print(x["id"], x.get("head_branch",""), x.get("head_sha",""), prs[0]["number"] if prs else 0, x.get("created_at",""))' 2>/dev/null)" || { log "$repo: bad PR runs JSON, skip tick"; return; }
  local to_cancel_pr=() rid br sha prn created jobs labels openpr
  while read -r rid br sha prn created; do
    [ -n "$rid" ] || continue
    case ",$ALLOW_BRANCHES," in *",$br,"*) log "$repo: PR run $rid branch $br allowlisted; untouched"; continue ;; esac
    if [ -n "$created" ] && [ $((NOW - $(date -u -j -f %Y-%m-%dT%H:%M:%SZ "$created" +%s 2>/dev/null || date -u -d "$created" +%s 2>/dev/null || echo "$NOW"))) -gt 86400 ]; then
      openpr="$(api "repos/$repo/pulls?head=${repo%%/*}:$br&state=open")" || { log "$repo: API failure reading PRs of branch $br, skip tick"; return; }
      if [ "$(printf '%s' "$openpr" | py 'print(len(d))')" = 0 ]; then log "$repo: orphan run $rid (>24h, branch $br has no open PR); skipped"; continue; fi
    fi
    jobs="$(api "repos/$repo/actions/runs/$rid/jobs?per_page=100")" || { log "$repo: API failure reading jobs of $rid, skip tick"; return; }
    printf '%s' "$jobs" | LABEL="$LABEL" python3 -c '
import sys,json,os
d=json.load(sys.stdin)
sys.exit(0 if any(j.get("status")=="queued" and os.environ["LABEL"] in (j.get("labels") or []) for j in d.get("jobs",[])) else 1)' 2>/dev/null || continue
    if [ "$prn" != 0 ]; then
      labels="$(api "repos/$repo/issues/$prn/labels")" || { log "$repo: API failure reading labels of #$prn, skip tick"; return; }
      if printf '%s' "$labels" | AL="$ALLOW_LABEL" python3 -c '
import sys,json,os
sys.exit(0 if any(l.get("name")==os.environ["AL"] for l in json.load(sys.stdin)) else 1)' 2>/dev/null; then
        log "$repo: PR #$prn run $rid labelled $ALLOW_LABEL; untouched"; continue
      fi
    fi
    to_cancel_pr+=("$rid:$sha:$prn:$br")
  done <<<"$cand"

  fair_gather "$repo"

  # ---- mutate ----
  local e rest
  for e in "${to_cancel_main[@]+"${to_cancel_main[@]}"}"; do
    cancel_run "$repo" "${e%%:*}" "cancel superseded main run ${e%%:*} ($repo, head ${e#*:})" || true
  done
  for e in "${to_cancel_pr[@]+"${to_cancel_pr[@]}"}"; do
    rid="${e%%:*}"; rest="${e#*:}"; sha="${rest%%:*}"; rest="${rest#*:}"; prn="${rest%%:*}"
    if cancel_run "$repo" "$rid" "cancel queued PR run $rid ($repo PR #$prn, head $sha) so main CI $nid gets a runner"; then
      [ "$DRY" = 1 ] || printf '%s\t%s\t%s\t%s\n' "$rid" "$prn" "$sha" "$NOW" >> "$ledger"
      if [ "$prn" != 0 ] && ! grep -qx "$prn:$sha" "$commented"; then
        if act "comment on $repo#$prn (head $sha)" -X POST "repos/$repo/issues/$prn/comments" -f "body=CI re-run deferred: main CI first (main run $nid is waiting for a heavy runner). Push or re-run to retry; the OS re-requests this run once main is green."; then
          [ "$DRY" = 1 ] || echo "$prn:$sha" >> "$commented"
        fi
      fi
    fi
  done
  fair_apply "$repo" "$nid"
  log "$repo: done (cancelled ${#to_cancel_main[@]} superseded main, ${#to_cancel_pr[@]} queued PR runs)"
}

# HELD-RERUN-1 (2026-11-17): the batch-first hold below keeps non-batch cancelled runs OFF the runners while the drain's batch needs them. It must not hold
# when nothing needs them: measured, 72 cancelled runs sat "held: drain batch goes first" for hours while both heavy runners were idle, because the batch
# file stays fresh as long as the drain keeps re-listing the same PRs. repo_idle = 0 when the repo has NO queued run younger than MAIN_FIRST_IDLE_RECENT_S
# (default 6 h: older queued runs are dead ghosts that never get a runner). An API error is "not idle" (hold), so the hold fails safe.
IDLE_RECENT_S="${MAIN_FIRST_IDLE_RECENT_S:-21600}"
repo_idle() { # <repo>
  local q
  q="$(api "repos/$1/actions/runs?status=queued&per_page=100")" || return 1
  printf '%s' "$q" | NOW_E="$NOW" RECENT="$IDLE_RECENT_S" python3 -c '
import sys,json,os,datetime
try:
    runs=json.load(sys.stdin).get("workflow_runs")
except Exception:
    sys.exit(1)
if not isinstance(runs,list): sys.exit(1)
now=int(os.environ["NOW_E"]); recent=int(os.environ["RECENT"])
def age(r):
    try: return now-int(datetime.datetime.strptime(r.get("created_at",""),"%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc).timestamp())
    except Exception: return 0   # an unreadable timestamp counts as fresh: a queued run we cannot date is not a ghost
sys.exit(0 if not [r for r in runs if age(r)<=recent] else 1)' 2>/dev/null
}

rerun_cancelled() { # <repo> <ledger> <main run id>
  local repo="$1" ledger="$2" nid="$3"
  [ -s "$ledger" ] || return 0
  local slugl idle="" lpend="" lpos rid prn sha ts pr st hsha ap grp tmp done_n=0 rows="" drops="" cleared="" seen="" run rst rcon rat rsha
  slugl="$(basename "$ledger")"; slugl="${slugl%%.*}"; load_launch "$slugl"
  # HELD-RERUN-1b: a launch-list PR with a run still in this ledger counts as PENDING (it is about to be re-run): non-launch held runs wait for it
  if [ -n "$LAUNCH_PRS" ]; then
    while IFS=$'\t' read -r rid prn _; do [ -n "$rid" ] || continue; [ -n "$(launch_pos "$prn")" ] && { lpend=1; break; }; done < "$ledger"
  fi
  # resolve each entry (PR open? head unchanged? approval time) BEFORE any re-run
  while IFS=$'\t' read -r rid prn sha ts; do
    [ -n "$rid" ] || continue
    case " $seen " in *" $rid "*) continue ;; esac   # duplicate ledger row: one request per id per tick
    seen="$seen $rid"
    if [ $((NOW - ts)) -gt 86400 ]; then log "$repo: ledger entry run $rid expired (>24h); dropped"; drops="$drops $rid"; continue; fi
    # re-request ONLY a run that is still completed+cancelled on its recorded head: another actor may have
    # re-run it already (success/failure/in_progress/queued) and a second rerun would restart a passing run
    run="$(api "repos/$repo/actions/runs/$rid")" || { log "$repo: API failure reading run $rid, kept in ledger this tick"; continue; }
    rst="$(printf '%s' "$run" | py 'print(d.get("status",""))')"; rcon="$(printf '%s' "$run" | py 'print(d.get("conclusion") or "")')"
    rat="$(printf '%s' "$run" | py 'print(d.get("run_attempt",""))')"; rsha="$(printf '%s' "$run" | py 'print(d.get("head_sha",""))')"
    if [ "$rst" != completed ] || [ "$rcon" != cancelled ]; then log "$repo: run $rid dropped: already ${rst:-unknown}${rcon:+/$rcon} attempt ${rat:-?}"; drops="$drops $rid"; continue; fi
    if [ -n "$rsha" ] && [ "$prn" != 0 ] && [ "$rsha" != "$sha" ]; then log "$repo: run $rid dropped: run head $rsha != ledger head $sha"; drops="$drops $rid"; continue; fi
    if [ "$prn" = 0 ]; then
      [ -n "$BATCH_PRS" ] || rows="$rows"$'\n'"29999999999 $ts $rid $prn $sha"
      continue
    fi
    pr="$(api "repos/$repo/pulls/$prn")" || { log "$repo: API failure reading PR #$prn, skip tick"; return; }
    st="$(printf '%s' "$pr" | py 'print(d.get("state",""))')"; hsha="$(printf '%s' "$pr" | py 'print(d["head"]["sha"])')"
    if [ "$st" != open ] || [ "$hsha" != "$sha" ]; then log "$repo: PR #$prn closed or head moved; run $rid dropped from ledger"; drops="$drops $rid"; continue; fi
    ap="$(api "repos/$repo/pulls/$prn/reviews?per_page=100")" || { log "$repo: API failure reading reviews of #$prn, skip tick"; return; }
    ap="$(printf '%s' "$ap" | python3 -c '
import sys,json
d=json.load(sys.stdin); last={}
for r in sorted(d,key=lambda r:r.get("submitted_at","")): last[r["user"]["login"]]=r
t=sorted(r["submitted_at"] for r in last.values() if r.get("state")=="APPROVED")
print(t[0] if t else "")' 2>/dev/null)" || ap=""
    # batch PRs first (0), then approved by approval time (1), then unapproved (2); non-batch HELD while a batch is fresh
    # held only while the batch needs the runners: with the repo idle (no recent queued run) the held run starts, in the old order (approved first), CAP per tick
    # sort key groups: 0 batch PRs, 1 launch-list PRs (in list order), 2 approved (by approval time), 3 unapproved
    lpos="$(launch_pos "$prn")"
    if in_batch "$prn"; then grp=0
    elif [ -n "$BATCH_PRS" ] && { [ -n "${idle:-}" ] || { if repo_idle "$repo"; then idle=1; else idle=0; fi; }; [ "$idle" = 0 ]; }; then log "$repo: PR #$prn run $rid held: drain batch [$BATCH_PRS] goes first"; continue
    elif [ -n "$BATCH_PRS" ] && [ -n "$LAUNCH_PRS" ] && [ -z "$lpos" ] && [ -n "$lpend" ]; then log "$repo: PR #$prn run $rid held: a launch-list PR is still pending [$LAUNCH_PRS]"; continue
    elif [ -n "$lpos" ]; then grp=1
    elif [ -n "$ap" ]; then grp=2; else grp=3; fi
    if [ "$grp" = 1 ]; then rows="$rows"$'\n'"1$(printf '%03d' "$lpos") $ts $rid $prn $sha"
    elif [ -n "$ap" ]; then rows="$rows"$'\n'"$grp$ap $ts $rid $prn $sha"; else rows="$rows"$'\n'"${grp}9999999999 $ts $rid $prn $sha"; fi
  done < "$ledger"
  local key _t
  while read -r key _t rid prn sha; do
    [ -n "$rid" ] || continue
    if [ "$done_n" -ge "$CAP" ]; then log "$repo: rerun cap $CAP reached; run $rid waits for the next tick"; continue; fi
    if act "re-request cancelled run $rid ($repo PR #$prn, head $sha) ${RERUN_WHY:-after main run $nid went green}" -X POST "repos/$repo/actions/runs/$rid/rerun"; then
      done_n=$((done_n+1)); cleared="$cleared $rid"
    else
      # act already logged FAILED once; never retry the same id forever
      drops="$drops $rid"; log "$repo: re-request of run $rid failed; dropped from ledger"
    fi
  done <<<"$(printf '%s\n' "$rows" | sort)"
  [ "$DRY" = 1 ] && return 0
  tmp="$ledger.tmp"; : > "$tmp"; seen=""
  while IFS=$'\t' read -r rid prn sha ts; do
    [ -n "$rid" ] || continue
    case " $cleared $drops $seen " in *" $rid "*) continue ;; esac
    seen="$seen $rid"
    printf '%s\t%s\t%s\t%s\n' "$rid" "$prn" "$sha" "$ts" >> "$tmp"
  done < "$ledger"
  mv -f "$tmp" "$ledger"
}

# ---- main lease (MAIN-LEASE-1) ----
# Re-request one cancelled run and CONFIRM it took (RERUN-VERIFIED-1 for this script): it must read back queued / in progress or on a higher
# attempt. 0 = confirmed, 1 = not (the caller keeps the row and retries on a later step).
mf_rerun() { # <repo> <run id> <description>
  local repo="$1" rid="$2" desc="$3" run att0 st att2
  run="$(api "repos/$repo/actions/runs/$rid")" || return 1
  att0="$(printf '%s' "$run" | py 'print(d.get("run_attempt",""))')"; [ -n "$att0" ] || return 1
  act "$desc" -X POST "repos/$repo/actions/runs/$rid/rerun" || return 1
  [ "$DRY" = 1 ] && return 0
  sleep "${MAIN_FIRST_VERIFY_WAIT:-20}"
  run="$(api "repos/$repo/actions/runs/$rid")" || return 1
  st="$(printf '%s' "$run" | py 'print(d.get("status",""))')"; att2="$(printf '%s' "$run" | py 'print(d.get("run_attempt",0))')"
  [ "$st" = queued ] || [ "$st" = in_progress ] || [ "${att2:-0}" -gt "$att0" ] 2>/dev/null
}

# Re-run what the lease cancelled. A row stays in the lease ledger until its run is confirmed re-queued, so a run that is still cancelling, or whose
# re-run did not take, is retried on the next step (after 5 failed steps it is reported as LEASE-RERUN-FAILED and dropped). A row is dropped when the
# run was already re-run by someone else, or its PR closed / its head moved. With a fresh drain batch a non-batch PR's run goes to the normal ledger.
lease_release_runs() { # <repo> <slug> <main run id>
  local repo="$1" slug="$2" nid="$3" lledger="$STATE/$2.lease.tsv" ledger="$STATE/$2.cancelled.tsv" tmp rid prn sha ts run rst rcon rsha pr st hsha tries
  [ -s "$lledger" ] || return 0
  load_batch "$slug"
  tmp="$lledger.tmp"; : > "$tmp"
  while IFS=$'\t' read -r rid prn sha ts; do
    [ -n "$rid" ] || continue
    run="$(api "repos/$repo/actions/runs/$rid")" || { log "$repo: lease: API failure reading run $rid; kept for the next step"; printf '%s\t%s\t%s\t%s\n' "$rid" "$prn" "$sha" "$ts" >> "$tmp"; continue; }
    rst="$(printf '%s' "$run" | py 'print(d.get("status",""))')"; rcon="$(printf '%s' "$run" | py 'print(d.get("conclusion") or "")')"; rsha="$(printf '%s' "$run" | py 'print(d.get("head_sha",""))')"
    if [ "$rst" != completed ]; then
      log "$repo: lease: run $rid is still ${rst:-unknown} (cancelling); kept for the next step"; printf '%s\t%s\t%s\t%s\n' "$rid" "$prn" "$sha" "$ts" >> "$tmp"; continue
    fi
    if [ "$rcon" != cancelled ]; then log "$repo: lease: run $rid dropped: already $rcon"; continue; fi
    if [ -n "$rsha" ] && [ "$prn" != 0 ] && [ "$rsha" != "$sha" ]; then log "$repo: lease: run $rid dropped: head moved"; continue; fi
    if [ "$prn" != 0 ]; then
      pr="$(api "repos/$repo/pulls/$prn")" || { log "$repo: lease: API failure reading PR #$prn; kept for the next step"; printf '%s\t%s\t%s\t%s\n' "$rid" "$prn" "$sha" "$ts" >> "$tmp"; continue; }
      st="$(printf '%s' "$pr" | py 'print(d.get("state",""))')"; hsha="$(printf '%s' "$pr" | py 'print(d["head"]["sha"])')"
      if [ "$st" != open ] || [ "$hsha" != "$sha" ]; then log "$repo: lease: PR #$prn closed or head moved; run $rid dropped"; continue; fi
      if [ -n "$BATCH_PRS" ] && ! in_batch "$prn"; then
        log "$repo: lease: PR #$prn run $rid held: drain batch [$BATCH_PRS] goes first; handed to the normal ledger"
        [ "$DRY" = 1 ] || printf '%s\t%s\t%s\t%s\n' "$rid" "$prn" "$sha" "$ts" >> "$ledger"; continue
      fi
    fi
    if mf_rerun "$repo" "$rid" "lease released: re-request cancelled run $rid ($repo PR #$prn, head $sha) after main run $nid"; then
      [ "$DRY" = 1 ] || echo "$nid $rid" >> "$STATE/$slug.lease.rerun"   # never re-cancelled under this main run
      rm -f "$STATE/$slug.lease.try.$rid"
    else
      tries=$(( $(cat "$STATE/$slug.lease.try.$rid" 2>/dev/null || echo 0) + 1 )); echo "$tries" > "$STATE/$slug.lease.try.$rid"
      if [ "$tries" -ge 5 ]; then log "$repo: LEASE-RERUN-FAILED run $rid not confirmed after $tries steps; dropped, needs a manual re-run"
      else log "$repo: lease: re-run of run $rid not confirmed (step $tries/5); kept"; printf '%s\t%s\t%s\t%s\n' "$rid" "$prn" "$sha" "$ts" >> "$tmp"; fi
    fi
  done < "$lledger"
  if [ "$DRY" = 1 ]; then rm -f "$tmp"; else mv -f "$tmp" "$lledger"; fi
}

# One step for one repo. Sets LEASE_STATE (a global: the caller must not use a subshell, the mutations log and write the ledger):
#   held      = main still has a queued job (or just went idle for the first of 2 steps): arrivals are cancelled / the lease is kept
#   releasing = the lease is over but some cancelled runs are not yet confirmed re-queued: keep stepping
#   idle      = nothing to do
lease_step() { # <repo>
  local repo="$1" slug lf lledger idlef mains newest nid nsha nstatus njobs qn rid br sha prn created prruns cand jobs labels idle
  slug="${repo//\//__}"; lf="$STATE/$slug.lease"; lledger="$STATE/$slug.lease.tsv"; idlef="$STATE/$slug.lease.idle"
  LEASE_STATE=idle
  touch "$lledger"
  mains="$(api "repos/$repo/actions/runs?branch=main&event=push&per_page=30")" || { log "$repo: lease: API failure reading main runs; lease state kept"; if [ -f "$lf" ]; then LEASE_STATE=held; elif [ -s "$lledger" ]; then LEASE_STATE=releasing; fi; return; }
  newest="$(printf '%s' "$mains" | WF="$WORKFLOW" python3 -c '
import sys,json,os
d=json.load(sys.stdin)
r=[x for x in d["workflow_runs"] if x.get("name","").lower()==os.environ["WF"].lower()]
r.sort(key=lambda x:x.get("created_at",""),reverse=True)
print(json.dumps(r[0]) if r else "")' 2>/dev/null)" || newest=""
  nid=""; nstatus=""
  if [ -n "$newest" ]; then nid="$(printf '%s' "$newest" | py 'print(d["id"])')"; nsha="$(printf '%s' "$newest" | py 'print(d["head_sha"])')"; nstatus="$(printf '%s' "$newest" | py 'print(d["status"])')"; fi
  qn=0
  if [ "$nstatus" = queued ] || [ "$nstatus" = in_progress ]; then
    njobs="$(api "repos/$repo/actions/runs/$nid/jobs?per_page=100")" || { log "$repo: lease: API failure reading jobs of main run $nid; lease state kept"; [ -f "$lf" ] && LEASE_STATE=held; return; }
    qn="$(printf '%s' "$njobs" | NOW="$NOW" GRACE="$LEASE_MIN_Q" python3 -c '
import sys,json,os,datetime
d=json.load(sys.stdin); now=int(os.environ["NOW"]); g=int(os.environ["GRACE"])
def ep(s): return int(datetime.datetime.strptime(s,"%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc).timestamp())
print(sum(1 for j in d.get("jobs",[]) if j.get("status")=="queued" and now-ep(j["created_at"])>=g))' 2>/dev/null)" || qn=0
  fi
  # MAIN-FIRST-MG-1: a merge-queue run (event merge_group, branch gh-readonly-queue/main/*) takes the lease EXACTLY like a queued main push run: with the
  # queue enabled it is the run that must reach the pool first. It only ever HOLDS the lease (it is never in a cancel list). The main push run keeps
  # priority as the holder when both have queued jobs.
  local mgruns mgid mgsha mgst mgq
  mgruns="$(api "repos/$repo/actions/runs?event=merge_group&per_page=30")" || { log "$repo: lease: API failure reading merge-queue runs; lease state kept"; if [ -f "$lf" ]; then LEASE_STATE=held; elif [ -s "$lledger" ]; then LEASE_STATE=releasing; fi; return; }
  while read -r mgid mgsha mgst; do
    [ -n "$mgid" ] || continue
    mgq="$(api "repos/$repo/actions/runs/$mgid/jobs?per_page=100" | NOW="$NOW" GRACE="$LEASE_MIN_Q" python3 -c '
import sys,json,os,datetime
d=json.load(sys.stdin); now=int(os.environ["NOW"]); g=int(os.environ["GRACE"])
def ep(s): return int(datetime.datetime.strptime(s,"%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc).timestamp())
print(sum(1 for j in d.get("jobs",[]) if j.get("status")=="queued" and now-ep(j["created_at"])>=g))' 2>/dev/null)" || mgq=0
    if [ "${qn:-0}" -le 0 ] && [ "${mgq:-0}" -gt 0 ]; then nid="$mgid"; nsha="$mgsha"; nstatus="$mgst"; qn="$mgq"
    elif [ "${qn:-0}" -le 0 ] && [ "$nstatus" != queued ] && [ "$nstatus" != in_progress ]; then nid="$mgid"; nsha="$mgsha"; nstatus=in_progress   # active queue run between waves: hysteresis applies
    fi
  done < <(printf '%s' "$mgruns" | WF="$WORKFLOW" python3 -c '
import sys,json,os
d=json.load(sys.stdin)
r=[x for x in d.get("workflow_runs",[]) if x.get("name","").lower()==os.environ["WF"].lower() and x.get("head_branch","").startswith("gh-readonly-queue/main/") and x.get("status") in ("queued","in_progress")]
r.sort(key=lambda x:x.get("created_at",""),reverse=True)
for x in r[:5]: print(x["id"], x.get("head_sha",""), x["status"])' 2>/dev/null)
  if [ "${qn:-0}" -le 0 ]; then
    if [ -f "$lf" ]; then
      # Hysteresis (review of #105): main queues its jobs in waves (`needs:`), so "no queued job" for one step is not "main is running". Release only when
      # main's run is no longer queued / in progress, or after 2 steps in a row with no queued job; the PR runs are then re-run once, not once per wave.
      if [ "$nstatus" = queued ] || [ "$nstatus" = in_progress ]; then
        idle=$(( $(cat "$idlef" 2>/dev/null || echo 0) + 1 )); [ "$DRY" = 1 ] || echo "$idle" > "$idlef"
        if [ "$idle" -lt 2 ]; then log "$repo: lease: main run $nid has no queued job ($idle/2); lease kept in case a later wave queues"; LEASE_STATE=held; return; fi
      fi
      log "$repo: lease released (main run ${nid:-none} ${nstatus:-gone}, no queued job): re-running the runs cancelled under it"
      [ "$DRY" = 1 ] || rm -f "$lf" "$idlef"
    fi
    lease_release_runs "$repo" "$slug" "${nid:-0}"
    [ -s "$lledger" ] && LEASE_STATE=releasing
    return
  fi
  # main has a queued job: hold the lease and cancel what arrived
  LEASE_STATE=held
  rm -f "$idlef"
  if [ ! -f "$lf" ]; then
    [ "$DRY" = 1 ] || printf '%s\t%s\n' "$nid" "$NOW" > "$lf"
    log "$repo: lease ACQUIRED by main run $nid ($nsha): $qn job(s) queued; PR runs arriving from now are cancelled until main's last job starts"
  fi
  load_batch "$slug"
  prruns="$(api "repos/$repo/actions/runs?status=queued&event=pull_request&per_page=100")" || { log "$repo: lease: API failure reading queued PR runs; skip this step"; return; }
  cand="$(printf '%s' "$prruns" | python3 -c '
import sys,json
d=json.load(sys.stdin)
for x in d["workflow_runs"]:
    if x.get("status")!="queued" or x.get("event","pull_request")!="pull_request" or x.get("head_branch","").startswith("gh-readonly-queue/"): continue   # a merge-queue run is never cancelled (MAIN-FIRST-MG-1)
    prs=x.get("pull_requests") or []
    print(x["id"], x.get("head_branch",""), x.get("head_sha",""), prs[0]["number"] if prs else 0, x.get("created_at",""))' 2>/dev/null)" || { log "$repo: lease: bad PR runs JSON; skip this step"; return; }
  while read -r rid br sha prn created; do
    [ -n "$rid" ] || continue
    grep -q "^$rid	" "$lledger" 2>/dev/null && continue                      # already cancelled under this lease
    grep -q "^$nid $rid$" "$STATE/$slug.lease.rerun" 2>/dev/null && continue  # this lease already re-ran it for this main run: never cancel it twice
    case ",$ALLOW_BRANCHES," in *",$br,"*) continue ;; esac                  # allow-listed branch: protected
    [ "$prn" != 0 ] && in_batch "$prn" && continue                           # the drain's batch: protected
    jobs="$(api "repos/$repo/actions/runs/$rid/jobs?per_page=100")" || { log "$repo: lease: API failure reading jobs of $rid; skip this step"; return; }
    # prints the runner pool label(s) the queued jobs ask for (ebda-mac / ebda-mac-light) so the cancel line below proves which pool was covered
    pool="$(printf '%s' "$jobs" | LABELS="$LEASE_LABELS" python3 -c '
import sys,json,os
d=json.load(sys.stdin); js=d.get("jobs",[]); want=os.environ["LABELS"].split()
# every job still queued (a run that has started is left alone) and at least one asks for a pool main also uses: heavy OR light
hit=sorted({l for j in js for l in (j.get("labels") or []) if l in want})
if js and all(j.get("status")=="queued" for j in js) and hit:
    print(",".join(hit)); sys.exit(0)
sys.exit(1)' 2>/dev/null)" || continue
    if [ "$prn" != 0 ]; then
      labels="$(api "repos/$repo/issues/$prn/labels")" || { log "$repo: lease: API failure reading labels of #$prn; skip this step"; return; }
      if printf '%s' "$labels" | AL="$ALLOW_LABEL" python3 -c '
import sys,json,os
sys.exit(0 if any(l.get("name")==os.environ["AL"] for l in json.load(sys.stdin)) else 1)' 2>/dev/null; then continue; fi   # fixes-main: protected
    fi
    if cancel_run "$repo" "$rid" "lease: cancel PR run $rid on arrival ($repo PR #$prn, head $sha, pool=$pool) so main run $nid gets a runner"; then
      [ "$DRY" = 1 ] || printf '%s\t%s\t%s\t%s\n' "$rid" "$prn" "$sha" "$NOW" >> "$lledger"
    fi
  done <<<"$cand"
}

# after the normal pass: keep the lease for every repo whose main still waits, one step per repo every LEASE_TICK s, at most LEASE_BUDGET s
lease_loop() {
  [ "$LEASE" = 1 ] || return 0
  local t=$SECONDS r any steps=0 max
  max=$(( LEASE_BUDGET / (LEASE_TICK > 0 ? LEASE_TICK : 1) )); [ "$max" -ge 1 ] || max=1
  while :; do
    any=0
    for r in $REPOS; do LEASE_STATE=idle; lease_step "$r"; if [ "$LEASE_STATE" = held ] || [ "$LEASE_STATE" = releasing ]; then any=1; fi; done
    steps=$((steps + 1))
    [ "$any" = 1 ] || break                      # no repo holds a lease: nothing to wait for
    [ "$DRY" = 1 ] && break                      # a dry run takes one step, never waits
    [ "$steps" -ge "$max" ] && { log "lease: budget (${LEASE_BUDGET}s) used; the lease carries into the next tick"; break; }
    sleep "$LEASE_TICK"
  done
}

log "tick start (dry=$DRY repos: $REPOS)"
# round-robin start: rotate the repo order every tick so no repo is always processed first (G16)
RR_FILE="$STATE/rr-cursor"; RR_N=0; for r in $REPOS; do RR_N=$((RR_N + 1)); done
RR_C="$(cat "$RR_FILE" 2>/dev/null || echo 0)"; case "$RR_C" in ''|*[!0-9]*) RR_C=0 ;; esac
RR_K=0; [ "$RR_N" -gt 0 ] && RR_K=$((RR_C % RR_N))
ORDER=""; i=0; for r in $REPOS; do [ "$i" -ge "$RR_K" ] && ORDER="$ORDER $r"; i=$((i + 1)); done
i=0; for r in $REPOS; do [ "$i" -lt "$RR_K" ] && ORDER="$ORDER $r"; i=$((i + 1)); done
[ "$DRY" = 1 ] || echo $((RR_C + 1)) > "$RR_FILE"
REPOS_CONFIGURED="$REPOS"; REPOS="${ORDER# }"
for r in $REPOS; do process_repo "$r"; done
lease_loop
if [ "$DRY" = 0 ] && command -v write_status >/dev/null 2>&1; then write_status main-first true "main-first tick ok" '{}'; fi
exit 0
