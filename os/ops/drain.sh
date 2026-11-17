#!/usr/bin/env bash
# Ebda AI OS - drain.sh: the durable merge loop for ONE repo (replaces the controller's drain2.sh / drain-fdn.sh).
#
#   drain.sh --repo OWNER/NAME --dir CHECKOUT [--gate PATH] [--hold-risky] [--name N] [--interval S]
#            [--stall-min 60] [--held-min 120] [--max-wait-min 20] [--main-workflow CI|none] [--max-ahead 3] [--starve-min 20] [--freeze] [--thaw-top 10] [--once]
#
# Every cycle: list open PRs into main that are green and mergeable, and merge each through the merge gate (head pinned, three
# consecutive polls, explicit required checks: never `gh pr merge` directly). With --hold-risky a PR labelled `risky-path` (set by
# the ai-review workflow) waits until it also carries `ai-review-passed`.
#   --gate     the merge-gate script, absolute or relative to --dir (default: $HOME/.claude/scripts/merge-gate.sh). It runs as
#              `<gate> <pr> <sha> --repo R --interval 30 --max-wait-min M`. DRAIN_REQUIRED_JSON, when set, becomes MERGE_GATE_REQUIRED_JSON.
#   --once     one cycle, then exit (tests, manual runs).
#   --main-workflow  the repo's push-CI workflow on main (default CI; `none` turns the main checks off). MAIN GATE (G74 / DRAIN-5): nothing
#              merges unless the newest completed main run is a success and no main run is queued/in progress at that moment, and at most
#              --max-ahead (default 3, DRAIN-BATCH-1) merges sit on top of the last green main commit (so up to 3 PRs may merge in a row; main is
#              re-read before EVERY gate call, and a main that turned red/pending mid-cycle stops the cycle). If the merge's own push run is not
#              registered yet the previous green run is the newest: bounded by --max-ahead. Unreadable = not green (fail closed). A PR
#              labelled `fixes-main` may merge while main is red (one per cycle) so the fix for a red main is never deadlocked. A main
#              run that ended CANCELLED on the newest commit is re-run once per run id+attempt (every main commit gets a full run).
#   HEAL (G47, DRAIN-HEAL-6/7): a PR whose only red is a CANCELLED/TIMED_OUT run (main-first preemption, hung job) gets that workflow's
#              run re-run once per run id+attempt (cap 20), for ANY workflow incl. "Deploy change label" - never only the required ones -
#              but ONLY while main is green with batch room and no main run is queued/in progress (a heal then is a cancel/re-run loop
#              that starves main CI), and at most (max-ahead - ahead) PRs per cycle, oldest first (DRAIN-HEAL-4).
#   STARVE (DRAIN-STARVE-1): runners take the NEWEST queued job first, so a required check on a `fixes-main` PR head can sit queued for
#              hours (#884, 2h20m). Any run on a fixes-main PR's current head queued > --starve-min (default 20) is cancelled and re-run
#              (back of the queue, picked next), at most 2 times per RUN ID and --starve-min apart (createdAt does not move on a re-run). Only current
#              fixes-main heads are touched, never one labelled `hold` (old ghost runs 409). Every re-run is read back and confirmed (RERUN-VERIFIED-1).
#   FREEZE (--freeze, Ruling MAIN-RED-FREEZE-1): while main CI is RED, every QUEUED run that is not on main and not a fixes-main PR head is
#              cancelled (they compete for the runners that main's fix needs; 101 queued runs once starved #884 for 3 h) and recorded in
#              <name>.frozen; a run whose cancel is refused (409, a ghost that holds no runner) is remembered and never retried. When main turns
#              green the --thaw-top (default 10) oldest PRs' frozen runs are re-run, AI review first, a batch per cycle; the rest follow.
#   MONEY (G49, MONEY-SHA-1): a `risky` PR needs the label money-review-passed AND the commit status `controller/money-review` = success on its
#              exact head sha (set by the controller after the independent review: `gh api repos/<repo>/statuses/<sha> -f state=success
#              -f context=controller/money-review`) by an account in OS_MONEY_STATUS_CREATORS (os.env, default the personal owner; empty = refuse all). A new head has no status,
#              so a PASS covers one head; a fetch error, an empty or non-list answer, or a status by any other creator refuses.
# Safety:
#   - OFF until switched over: does nothing unless $OS_STATE_DIR/drain/<name>.enabled exists (so installing the launchd job never
#     races a controller's own loop). Turn on: touch it. Turn off: rm it, or touch <name>.stop. A global ~/.claude/handoff/drain.stop
#     also stops it (same file the controller loops honour).
#   - one instance per repo (lock drain-<name>) and one gate per PR (lock drain-<name>-pr<N>, plus a gate-process check): launchd
#     restarts it every 5 minutes, a second copy exits at once.
#   - a PR whose gate failed is not retried on the same head for 10 minutes.
# Heartbeat + stall: every cycle writes $OS_STATE_DIR/drain/<name>.heartbeat and the os-state status; every 10 minutes it POSTs a
# findings snapshot (source drain-<name>) to the brain. Progress = a merge, or nothing waiting. Eligible PRs waiting with no progress for
# --stall-min opens ONE finding `drain-stall` (P1; the brain alerts once per finding and resolves it when the next snapshot omits it);
# risky PRs held longer than --held-min open `drain-held` (digest). Brain unreachable: the finding stays visible in the heartbeat file.
# Exit: 0 normally / when off or stopped, 2 usage.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/args.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/args.sh" || exit 2
args_help "${BASH_SOURCE[0]}" "$@"
REPO=""; DIR=""; GATE="$HOME/.claude/scripts/merge-gate.sh"; HOLD=0; NAME=""; INTERVAL=60; STALL_MIN=60; HELD_MIN=120; MAXWAIT=20; ONCE=0; MAIN_WF="CI"; MAX_AHEAD=3; STARVE_MIN=20; STARVE_CAP=2; FREEZE=0; THAW_TOP=10
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:?}"; shift ;; --dir) DIR="${2:?}"; shift ;; --gate) GATE="${2:?}"; shift ;; --hold-risky) HOLD=1 ;;
    --name) NAME="${2:?}"; shift ;; --interval) INTERVAL="${2:?}"; shift ;; --stall-min) STALL_MIN="${2:?}"; shift ;;
    --held-min) HELD_MIN="${2:?}"; shift ;; --max-wait-min) MAXWAIT="${2:?}"; shift ;; --once) ONCE=1 ;;
    --main-workflow) MAIN_WF="${2:?}"; shift ;; --max-ahead) MAX_AHEAD="${2:?}"; shift ;; --starve-min) STARVE_MIN="${2:?}"; shift ;; --freeze) FREEZE=1 ;; --thaw-top) THAW_TOP="${2:?}"; shift ;;
    *) args_unknown "${BASH_SOURCE[0]}" "$1" ;;
  esac
  shift
done
[ -n "$REPO" ] && [ -n "$DIR" ] || { echo "drain: --repo and --dir are required (try --help)" >&2; exit 2; }
case "$REPO" in */*) ;; *) echo "drain: --repo must be OWNER/NAME" >&2; exit 2 ;; esac
whole() { case "$2" in ''|*[!0-9]*) echo "drain: $1 must be a whole number" >&2; exit 2 ;; esac; }
whole --interval "$INTERVAL"; whole --stall-min "$STALL_MIN"; whole --held-min "$HELD_MIN"; whole --max-wait-min "$MAXWAIT"; whole --max-ahead "$MAX_AHEAD"; whole --starve-min "$STARVE_MIN"; whole --thaw-top "$THAW_TOP"
[ -n "$NAME" ] || NAME="${REPO##*/}"
case "$NAME" in *[!A-Za-z0-9._-]*|'') echo "drain: --name must be [A-Za-z0-9._-]" >&2; exit 2 ;; esac
[ -d "$DIR" ] || { echo "drain: --dir $DIR does not exist" >&2; exit 2; }
case "$GATE" in /*) ;; *) GATE="$DIR/$GATE" ;; esac
[ -n "${DRAIN_REQUIRED_JSON:-}" ] && export MERGE_GATE_REQUIRED_JSON="$DRAIN_REQUIRED_JSON"

# shellcheck source=lib/os-config.sh
. "$HERE/lib/os-config.sh" 2>/dev/null && os_config_load 2>/dev/null || true
# shellcheck source=lib/single-instance.sh
. "$HERE/lib/single-instance.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/single-instance.sh" || exit 2
# shellcheck source=lib/brain-post.sh
. "$HERE/lib/brain-post.sh" 2>/dev/null || true
. "$HERE/lib/os-state.sh" 2>/dev/null || true
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"

SD="${OS_STATE_DIR:-$HOME/.whisky-os-state}/drain"; mkdir -p "$SD"
ENABLED="$SD/$NAME.enabled"; STOP="$SD/$NAME.stop"; GLOBAL_STOP="$HOME/.claude/handoff/drain.stop"
HB="$SD/$NAME.heartbeat"; PROG="$SD/$NAME.progress"; POSTED="$SD/$NAME.last-post"
log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*"; }
halted() { [ -f "$STOP" ] || [ -f "$GLOBAL_STOP" ]; }
[ -f "$ENABLED" ] || { log "drain $NAME: not switched over ($ENABLED absent); idle"; exit 0; }
halted && { log "drain $NAME: stop file present; idle"; exit 0; }
single_instance "drain-$NAME"

epoch() { date +%s; }
read_int() { local v; v="$(cat "$1" 2>/dev/null || true)"; case "$v" in ''|*[!0-9]*) echo 0 ;; *) echo "$v" ;; esac; }

# prints "<pr> <sha> <risky 0|1> <passed 0|1>" per green+mergeable PR; exit 3 when GitHub cannot be read (unknown is not "nothing")
list_ready() {
  local raw; raw="$(gh pr list --repo "$REPO" --state open --base main --limit 60 --json number,mergeable,statusCheckRollup,isDraft,labels,headRefOid 2>/dev/null)" || return 3
  # eligibility lives in ONE place (lib/drain_eligible.py), shared with loop-watchdog's stall count (G15)
  printf '%s' "$raw" | python3 -I "$HERE/lib/drain_eligible.py" --mode drain 2>/dev/null || return 3
}

# PR numbers repeat across repos: match this repo too, or a gate on another repo's #N would skip ours
gate_running() { pgrep -f "merge-gate.sh $1 .*--repo $REPO " >/dev/null 2>&1; }

# Re-run a run and VERIFY it took (2026-11-17: a cancel + re-run left #811's CI and a main CI run cancelled for good, because the re-run was
# asked for while the run was still cancelling, failed silently, and the once-per-run marker stopped any retry). Waits for the run to be
# `completed` (a run that is still cancelling cannot be re-run), re-runs, then reads the run back: it must be queued / in progress or on a
# higher attempt. Up to 3 tries. Returns 0 only when the re-run is confirmed; 1 = still dead, the caller must NOT mark it done.
rerun_verified() { # $1 = run id, rest = extra `gh run rerun` args (e.g. --failed)
  local id="$1" i w st st2 att0 att2; shift
  att0="$(gh run view "$id" --repo "$REPO" --json attempt --jq .attempt 2>/dev/null)" || att0=""
  [ -n "$att0" ] || return 1   # cannot read the run's attempt now: nothing to compare a later read with, so never confirm (a failed first read used to make any later read look like progress)
  for i in 1 2 3; do
    for w in 1 2 3 4 5 6; do
      st="$(gh run view "$id" --repo "$REPO" --json status --jq .status 2>/dev/null)" || st=""
      [ "$st" = completed ] && break
      sleep "${RERUN_WAIT:-10}"
    done
    gh run rerun "$id" --repo "$REPO" "$@" >/dev/null 2>&1
    sleep "${RERUN_VERIFY_SLEEP:-5}"
    read -r st2 att2 <<EOV
$(gh run view "$id" --repo "$REPO" --json status,attempt --jq '"\(.status) \(.attempt)"' 2>/dev/null)
EOV
    if [ "$st2" = queued ] || [ "$st2" = in_progress ] || [ "${att2:-0}" -gt "${att0:-0}" ] 2>/dev/null; then return 0; fi
  done
  return 1
}
# A re-run that could not be confirmed is retried on later cycles, at most 3 times per run id, then reported once and left to a human.
rerun_failed_note() { # $1 = id, $2 = what
  local f="$SD/$NAME.rerun-fails-$1" n
  n=$(( $(cat "$f" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$f"
  if [ "$n" -ge 3 ]; then
    echo "$1" >> "$SD/$NAME.rerun-failed"
    log "RERUN-FAILED run $1 ($2): not confirmed after $n cycles x 3 tries, left cancelled; needs a manual re-run"
    return 0
  fi
  log "re-run of run $1 ($2) not confirmed (cycle $n/3), will retry"
}
rerun_gaveup() { grep -qxF "$1" "$SD/$NAME.rerun-failed" 2>/dev/null; }

DE="$HERE/lib/drain_eligible.py"
# MAIN GATE. Sets MAIN_VERDICT (green|full|red|pending|unverified|unknown|off), MAIN_SHA, MAIN_AHEAD. Rc 0 = may merge ordinary PRs.
main_gate() {
  MAIN_VERDICT=off; MAIN_SHA=-; MAIN_AHEAD=0
  [ "$MAIN_WF" = none ] && return 0
  local runs green ahead v rid att
  runs="$(gh run list --repo "$REPO" --branch main --event push --workflow "$MAIN_WF" --limit 15 --json databaseId,headSha,status,conclusion,attempt 2>/dev/null)" || { MAIN_VERDICT=unknown; return 1; }
  green="$(printf '%s' "$runs" | python3 -I -c 'import json,sys
for r in json.load(sys.stdin):
    if r.get("status") == "completed" and r.get("conclusion") == "success": print(r["headSha"]); break' 2>/dev/null)"
  ahead=0
  if [ -n "$green" ]; then
    ahead="$(gh api "repos/$REPO/compare/$green...main" 2>/dev/null | python3 -I -c 'import json,sys;print(json.load(sys.stdin).get("ahead_by",99))' 2>/dev/null)" || ahead=99
    case "$ahead" in ''|*[!0-9]*) ahead=99 ;; esac
  else ahead=99; fi
  MAIN_AHEAD="$ahead"
  read -r v MAIN_SHA rid att <<EOV
$(printf '%s' "$runs" | python3 -I "$DE" --mode main --max-ahead "$MAX_AHEAD" --ahead "$ahead" 2>/dev/null || echo "unknown - 0 0")
EOV
  MAIN_VERDICT="${v:-unknown}"
  if [ "$MAIN_VERDICT" = unverified ] && [ "${rid:-0}" -gt 0 ] && [ ! -f "$SD/$NAME.healed-main-$rid-a$att" ] && ! rerun_gaveup "$rid"; then
    # G74: the newest main commit has no completed run: ask for one, and confirm it took (marked done only once it did)
    if rerun_verified "$rid"; then : > "$SD/$NAME.healed-main-$rid-a$att"; log "main run $rid on $MAIN_SHA ended cancelled: re-run confirmed"
    else rerun_failed_note "$rid" "main on $MAIN_SHA"; fi
  fi
  case "$MAIN_VERDICT" in green|off) return 0 ;; *) return 1 ;; esac
}

# G47: re-run cancelled/timed-out runs of otherwise-eligible PRs. Caller guarantees main is green with room and nothing pending.
heal_pass() { # $1 = how many PRs may be healed this cycle
  local room="$1" p sha id att n=0
  [ "$room" -gt 0 ] || return 0
  while read -r p sha; do
    [ -n "$p" ] || continue
    [ "$n" -lt "$room" ] || break
    gh run list --repo "$REPO" --commit "$sha" --limit 60 --json databaseId,workflowName,status,conclusion,attempt 2>/dev/null \
      | python3 -I "$DE" --mode runs 2>/dev/null | while read -r id att; do
        [ -n "$id" ] || continue
        [ -f "$SD/$NAME.healed-$id-a$att" ] && continue
        [ "${att:-1}" -ge 20 ] && continue   # main-first preemption counts too, but not forever
        rerun_gaveup "$id" && continue
        if rerun_verified "$id" --failed; then : > "$SD/$NAME.healed-$id-a$att"; log "HEAL #$p re-run $id confirmed (cancelled on ${sha:0:8})"
        else rerun_failed_note "$id" "heal #$p"; fi
      done
    n=$((n + 1))
  done <<EOH
$(gh pr list --repo "$REPO" --state open --base main --limit 60 --json number,mergeable,statusCheckRollup,isDraft,labels,headRefOid 2>/dev/null | python3 -I "$DE" --mode heal 2>/dev/null | sort -n)
EOH
}

# Ruling MONEY-SHA-1 (supersedes DRAIN-MONEY-2's label-vs-commit-date check, which the review of 2026-11-17 showed fails open on an API error and trusts a
# client-set committer date): a `risky` PR merges only when the controller has set the commit status `controller/money-review` = success on the EXACT
# head sha (`gh api repos/<repo>/statuses/<sha> -f state=success -f context=controller/money-review`), after the independent review. A new head has no
# such status, so a PASS covers one head by construction. Any fetch error, empty list or non-list body = refuse.
MONEY_CONTEXT="controller/money-review"
# Only a status created by one of the accounts in $OS_MONEY_STATUS_CREATORS (os.env / os-config.sh, read through os_config_load; no literal here) counts:
# any workflow of a PR can post a status with GITHUB_TOKEN (creator github-actions[bot]), so a PR could approve itself. Empty or unset after config load
# = NOBODY is allowed: every risky PR is refused (logged once per cycle). Residual: agents share the controller's gh account, so this stops workflow
# self-approval, not a rogue agent; the controller-only rule stays procedural.
MONEY_CREATORS="${OS_MONEY_STATUS_CREATORS:-}"
MONEY_CREATORS="${MONEY_CREATORS//[[:space:]]/,}"
money_at_head() { # $1 = PR, $2 = head sha
  local st rc
  if [ -z "${MONEY_CREATORS//,/}" ]; then log "money creators not configured (OS_MONEY_STATUS_CREATORS empty): refusing every risky PR"; return 1; fi
  st="$(mktemp)"
  if ! gh api "repos/$REPO/commits/$2/statuses" --paginate > "$st" 2>/dev/null; then rm -f "$st"; return 1; fi
  python3 -I "$DE" --mode status-ok --context "$MONEY_CONTEXT" --creators "$MONEY_CREATORS" --file "$st" 2>/dev/null; rc=$?
  rm -f "$st"; return $rc
}

# DRAIN-STARVE-1: requeue runs of fixes-main PR heads that sat queued too long. Runs every cycle, whatever main's state (main is red when this matters).
starve_pass() {
  local p sha id att now n last
  now="$(epoch)"
  while read -r p sha; do
    [ -n "$p" ] || continue
    gh run list --repo "$REPO" --commit "$sha" --limit 60 --json databaseId,status,createdAt,attempt 2>/dev/null \
      | python3 -I "$DE" --mode starved --min "$STARVE_MIN" 2>/dev/null | while read -r id att; do
        [ -n "$id" ] || continue
        rerun_gaveup "$id" && continue
        # Per RUN ID, not per attempt: `createdAt` does not move on a re-run, so a re-queued run still looks old and an attempt-keyed marker never
        # matched (the review of 2026-11-17: an endless cancel / re-run loop). At most $STARVE_CAP requeues per run id, at least $STARVE_MIN min apart.
        n="$(read_int "$SD/$NAME.starve-n-$id")"; last="$(read_int "$SD/$NAME.starve-t-$id")"
        [ "$n" -ge "$STARVE_CAP" ] && continue
        [ "$last" -gt 0 ] && [ $((now - last)) -lt $((STARVE_MIN * 60)) ] && continue
        # cancel, then re-run and CONFIRM it is queued again; counted only once it is (a cancelled run that never came back is what took #811's CI
        # and a main run out on 2026-11-17)
        if [ -f "$SD/$NAME.rerun-fails-$id" ] || gh run cancel "$id" --repo "$REPO" >/dev/null 2>&1; then
          # (a later cycle after a failed re-run only retries the re-run: the run is already cancelled, never cancel it twice)
          if rerun_verified "$id"; then echo $((n + 1)) > "$SD/$NAME.starve-n-$id"; echo "$now" > "$SD/$NAME.starve-t-$id"; log "STARVE #$p run $id queued >${STARVE_MIN}m: cancelled and re-queued (confirmed, $((n + 1))/$STARVE_CAP)"
          else rerun_failed_note "$id" "starve #$p"; fi
        else echo "$STARVE_CAP" > "$SD/$NAME.starve-n-$id"; fi   # cancel refused (409 ghost, holds no runner): never retried
      done
  done <<EOS
$(gh pr list --repo "$REPO" --state open --base main --label fixes-main --limit 30 --json number,headRefOid,labels --jq '.[]|select(all(.labels[]; .name != "hold"))|"\(.number) \(.headRefOid)"' 2>/dev/null)
EOS
}

# MAIN-RED-FREEZE-1: main is red -> cancel queued runs that are not main's fix. Runs only when --freeze is on and the verdict is `red`
# (not pending / unverified / unknown: a main run in progress or unreadable CI is no reason to cancel other people's work).
freeze_pass() {
  [ "$FREEZE" = 1 ] && [ "$MAIN_VERDICT" = red ] || return 0
  local keep id br sha wf att cout crc
  keep="$(gh pr list --repo "$REPO" --state open --label fixes-main --limit 30 --json headRefName --jq '[.[].headRefName]|join(",")' 2>/dev/null)" || return 0
  gh run list --repo "$REPO" --status queued --limit 300 --json databaseId,headBranch,headSha,workflowName,attempt 2>/dev/null \
    | python3 -I "$DE" --mode freeze --keep "$keep" 2>/dev/null | while IFS=$'\t' read -r id br sha wf att; do
      [ -n "$id" ] || continue
      grep -qxF "$id" "$SD/$NAME.frozen-ghost" 2>/dev/null && continue
      grep -q "^$id	" "$SD/$NAME.frozen" 2>/dev/null && continue
      cout="$(gh run cancel "$id" --repo "$REPO" 2>&1)"; crc=$?
      if [ "$crc" = 0 ]; then
        printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$br" "$sha" "$wf" "$att" >> "$SD/$NAME.frozen"
        log "FREEZE main red: cancelled queued run $id ($wf on $br)"
      elif grep -q "409" <<<"$cout"; then echo "$id" >> "$SD/$NAME.frozen-ghost"   # 409: a ghost that holds no runner, never retried
      else log "FREEZE: cancel of run $id failed (not a 409, will retry): $(printf '%s' "$cout" | head -c 120)"; fi
    done
}

# Main is green again: re-run the frozen runs of the oldest --thaw-top PRs (AI review first), drop them from the record.
thaw_pass() {
  [ "$FREEZE" = 1 ] && [ "$MAIN_VERDICT" = green ] && [ -s "$SD/$NAME.frozen" ] || return 0
  local order batch id br sha wf att n=0 opens cur
  order="$(gh pr list --repo "$REPO" --state open --base main --limit 100 --json number,headRefName --jq 'sort_by(.number)|map(.headRefName)|join(",")' 2>/dev/null)" || return 0
  # a frozen run is re-run only while its PR is still open on the head it was frozen at (the sha is stored abbreviated: compare by prefix)
  opens="$(gh pr list --repo "$REPO" --state open --base main --limit 100 --json headRefName,headRefOid --jq '.[]|"\(.headRefName)=\(.headRefOid)"' 2>/dev/null)" || return 0
  batch="$(python3 -I "$DE" --mode thaw --branches "$order" --top "$THAW_TOP" < "$SD/$NAME.frozen" 2>/dev/null)"
  [ -n "$batch" ] || return 0
  while IFS=$'\t' read -r id br sha wf att; do
    [ -n "$id" ] || continue
    cur="$(printf '%s\n' "$opens" | sed -n "s|^$br=||p" | head -1)"
    if [ -z "$cur" ] || [ "${cur#"$sha"}" = "$cur" ]; then
      log "THAW run $id dropped: ${cur:+head moved on }${cur:-PR closed or not open} ($wf on $br)"
      grep -v "^$id	" "$SD/$NAME.frozen" > "$SD/$NAME.frozen.tmp" 2>/dev/null; mv "$SD/$NAME.frozen.tmp" "$SD/$NAME.frozen"; continue
    fi
    if rerun_verified "$id"; then log "THAW main green: re-run $id confirmed ($wf on $br)"
    else rerun_failed_note "$id" "thaw $wf on $br"; rerun_gaveup "$id" || continue   # keep it in the record for the next cycle
    fi
    grep -v "^$id	" "$SD/$NAME.frozen" > "$SD/$NAME.frozen.tmp" 2>/dev/null; mv "$SD/$NAME.frozen.tmp" "$SD/$NAME.frozen"
    n=$((n + 1))
  done <<EOT
$batch
EOT
}

cycle() {
  local ready rc now merged=0 eligible=0 held=0 p sha risky passed fk fail_at oldest_held hf a
  now="$(epoch)"
  ready="$(list_ready)"; rc=$?
  if [ "$rc" -ne 0 ]; then log "cannot read PRs of $REPO; skipping this cycle (no progress claimed, no stall judged)"; return 3; fi
  oldest_held=0
  local gate_ok=1 fixes_only=0 heal_room ahead0 ahead_eff
  starve_pass
  main_gate || gate_ok=0
  if [ "$MAIN_VERDICT" = unknown ]; then UNK_STREAK=$(( $(read_int "$SD/$NAME.unknown-streak") + 1 )); else UNK_STREAK=0; fi
  echo "$UNK_STREAK" > "$SD/$NAME.unknown-streak"
  freeze_pass
  thaw_pass
  if [ "$gate_ok" = 0 ]; then
    if [ "$MAIN_VERDICT" = unknown ]; then
      log "main CI unreadable ($MAIN_WF), streak $UNK_STREAK: merging nothing this cycle"
      [ "$UNK_STREAK" -ge 3 ] && log "ALERT: no main $MAIN_WF run could be read for $UNK_STREAK cycles in a row; if the workflow name is wrong pass --main-workflow, or --main-workflow none"
      return 3
    fi
    log "main not green ($MAIN_VERDICT $MAIN_SHA, +$MAIN_AHEAD since green): only fixes-main PRs"; fixes_only=1
  elif [ "$MAIN_VERDICT" = green ]; then
    heal_room=$((MAX_AHEAD - MAIN_AHEAD)); [ "$heal_room" -gt 0 ] && heal_pass "$heal_room"
  fi
  ahead0="$MAIN_AHEAD"
  while read -r p sha risky passed fixes moneyneeded; do
    [ -n "$p" ] || continue
    ahead_eff=$((ahead0 + merged)); [ "$MAIN_AHEAD" -gt "$ahead_eff" ] && ahead_eff="$MAIN_AHEAD"
    if [ "$MAIN_VERDICT" != off ] && [ "$ahead_eff" -ge "$MAX_AHEAD" ] && [ "$fixes_only" = 0 ]; then log "batch full ($MAX_AHEAD merges on the last green main): waiting for main CI"; break; fi
    if [ "$HOLD" = 1 ] && [ "$risky" = 1 ] && [ "$passed" != 1 ]; then
      held=$((held + 1)); log "HOLD #$p risky, awaiting ai-review-passed"
      hf="$SD/$NAME.held.$p"; [ -f "$hf" ] || epoch > "$hf"
      continue
    fi
    eligible=$((eligible + 1))
    if [ "$fixes_only" = 1 ]; then
      # red main: only a PR labelled fixes-main may merge, one per cycle, and only when main is red (not pending/full/unverified)
      if [ "$fixes" != 1 ] || [ "$MAIN_VERDICT" != red ] || [ "$merged" -gt 0 ]; then continue; fi
    fi
    if [ "$moneyneeded" = 1 ] && ! money_at_head "$p" "$sha"; then log "HOLD #$p no ${MONEY_CONTEXT} success on head ${sha:0:8} (a PASS covers one head; fetch errors refuse)"; continue; fi
    # Re-read main before EVERY gate call (a gate waits up to --max-wait-min, so main can turn red or pending between two merges of one cycle).
    if [ "$merged" -gt 0 ] || [ "$fixes_only" = 0 ]; then
      if main_gate; then :; else
        if [ "$MAIN_VERDICT" = unknown ]; then log "main CI unreadable before gating #$p: stopping this cycle"; break; fi
        if [ "$fixes" != 1 ] || [ "$MAIN_VERDICT" != red ] || [ "$merged" -gt 0 ]; then log "main is $MAIN_VERDICT ($MAIN_SHA) before gating #$p: not gating"; continue; fi
      fi
      ahead_eff=$((ahead0 + merged)); [ "$MAIN_AHEAD" -gt "$ahead_eff" ] && ahead_eff="$MAIN_AHEAD"
      if [ "$MAIN_VERDICT" != off ] && [ "$MAIN_VERDICT" != red ] && [ "$ahead_eff" -ge "$MAX_AHEAD" ]; then log "batch full ($MAX_AHEAD ahead of the last green main): waiting for main CI"; break; fi
    fi
    fk="$SD/$NAME.failed.$p.$sha"; fail_at="$(read_int "$fk")"
    if [ "$fail_at" -gt 0 ] && [ $((now - fail_at)) -lt 600 ]; then log "skip #$p ${sha:0:8}: gate failed $((now - fail_at))s ago"; continue; fi
    gate_running "$p" && { log "skip #$p: a gate is already running"; continue; }
    si_acquire "drain-$NAME-pr$p" >/dev/null 2>&1 || { log "skip #$p: another drain holds it"; continue; }
    log "gate #$p ${sha:0:8}"
    # run from the TARGET checkout: the gate derives the required checks from <cwd toplevel>/.github/workflows (launchd's cwd is /)
    if ( cd "$DIR" && "$GATE" "$p" "$sha" --repo "$REPO" --interval 30 --max-wait-min "$MAXWAIT" ); then
      log "MERGED #$p"; merged=$((merged + 1)); epoch > "$PROG"; rm -f "$SD/$NAME.held.$p"
    else
      log "gate failed #$p ${sha:0:8}"; epoch > "$fk"
    fi
    si_release "drain-$NAME-pr$p"
  done <<EOF2
$ready
EOF2
  # forget held markers of PRs that are no longer held (merged, closed, or reviewed)
  for hf in "$SD/$NAME.held."*; do
    [ -f "$hf" ] || continue; p="${hf##*.held.}"
    printf '%s\n' "$ready" | awk -v n="$p" '$1==n && $4!=1 {f=1} END{exit !f}' || rm -f "$hf"
  done
  # nothing waiting is progress; a merge already stamped it
  [ "$eligible" -eq 0 ] && epoch > "$PROG"
  for hf in "$SD/$NAME.held."*; do
    [ -f "$hf" ] || continue
    a="$(read_int "$hf")"
    if [ "$oldest_held" -eq 0 ] || [ "$a" -lt "$oldest_held" ]; then oldest_held="$a"; fi
  done
  CYC_ELIGIBLE="$eligible"; CYC_HELD="$held"; CYC_MERGED="$merged"; CYC_OLDEST_HELD="$oldest_held"
  return 0
}

heartbeat() { # $1 = cycle rc
  local now prog stalled=0 heldlong=0 stall_age=0 findings="[]" summary last
  now="$(epoch)"; prog="$(read_int "$PROG")"; [ "$prog" -gt 0 ] || { epoch > "$PROG"; prog="$now"; }
  if [ "$1" = 0 ]; then
    stall_age=$(( (now - prog) / 60 ))
    [ "${CYC_ELIGIBLE:-0}" -gt 0 ] && [ "$stall_age" -ge "$STALL_MIN" ] && stalled=1
    [ "${CYC_OLDEST_HELD:-0}" -gt 0 ] && [ $(( (now - CYC_OLDEST_HELD) / 60 )) -ge "$HELD_MIN" ] && heldlong=1
    findings="$(python3 -I - "$REPO" "$NAME" "$stalled" "$heldlong" "${CYC_ELIGIBLE:-0}" "${CYC_HELD:-0}" "$stall_age" "$STALL_MIN" "$HELD_MIN" <<'PY'
import json, sys
repo, name, stalled, held, elig, nheld, age, smin, hmin = sys.argv[1:10]
out = []
if stalled == "1":
    out.append({"source": "drain-" + name, "kind": "drain-stall", "key": repo, "repo": repo, "severity": "P1",
                "title": "drain for %s is stalled: %s green PR(s) waiting, no merge for %s min" % (repo, elig, age),
                "detail": {"eligible": int(elig), "minutesWithoutProgress": int(age), "stallMin": int(smin)}})
if held == "1":
    out.append({"source": "drain-" + name, "kind": "drain-held", "key": repo + "|held", "repo": repo, "severity": "P2",
                "title": "%s risky PR(s) in %s have waited over %s min for ai-review-passed (is the review secret set?)" % (nheld, repo, hmin),
                "detail": {"held": int(nheld), "heldMin": int(hmin)}})
print(json.dumps(out))
PY
)"
  fi
  # a drain that cannot read main's workflow merges NOTHING and used to say nothing (wrong --main-workflow name = `runs []` = unknown, forever)
  if [ "$(read_int "$SD/$NAME.unknown-streak")" -ge 3 ]; then
    findings="$(python3 -I -c 'import json,sys; f=json.loads(sys.argv[1]); f.append({"source":"drain-"+sys.argv[3],"kind":"drain-main-unreadable","key":sys.argv[2]+"|main","repo":sys.argv[2],"severity":"P1","title":"drain for %s cannot read main workflow %s: nothing merges (wrong --main-workflow name?)" % (sys.argv[2], sys.argv[4]),"detail":{"streak":int(sys.argv[5]),"mainWorkflow":sys.argv[4]}}); print(json.dumps(f))' "$findings" "$REPO" "$NAME" "$MAIN_WF" "$(read_int "$SD/$NAME.unknown-streak")")"
  fi
  summary="eligible=${CYC_ELIGIBLE:-?} held=${CYC_HELD:-?} merged=${CYC_MERGED:-0} stalled=$stalled"
  printf '{"at":%s,"cycleRc":%s,"stalled":%s,"heldLong":%s,"minutesWithoutProgress":%s}\n' "$now" "$1" \
    "$([ "$stalled" = 1 ] && echo true || echo false)" "$([ "$heldlong" = 1 ] && echo true || echo false)" "$stall_age" > "$HB"
  if command -v write_status >/dev/null 2>&1; then
    if [ "$stalled" = 1 ]; then write_status "drain-$NAME" false "$summary" '{}'; else write_status "drain-$NAME" true "$summary" '{}'; fi
  fi
  [ "$1" = 0 ] || [ "$(read_int "$SD/$NAME.unknown-streak")" -ge 3 ] || return 0
  last="$(read_int "$POSTED")"
  # post every 10 min, and at once when the finding set changed (opened or cleared)
  if [ $((now - last)) -ge 600 ] || [ "$findings" != "$(cat "$SD/$NAME.last-findings" 2>/dev/null)" ]; then
    if command -v _brain_env >/dev/null 2>&1; then
      _brain_env
      if [ -n "${OS_BRAIN_URL:-}" ] && [ -n "${INGEST_TOKEN:-}" ] && [ "${DRY_RUN:-0}" != 1 ]; then
        python3 -I -c 'import json,sys; print(json.dumps({"findings": json.loads(sys.argv[1]), "reconcile": {"source": "drain-" + sys.argv[2], "keep": []}}))' "$findings" "$NAME" > "$SD/$NAME.snapshot.json"
        if curl -fsS -m 30 -o /dev/null -X POST "${OS_BRAIN_URL%/}/findings" -H "Authorization: Bearer $INGEST_TOKEN" -H 'content-type: application/json' --data-binary "@$SD/$NAME.snapshot.json" 2>/dev/null; then
          epoch > "$POSTED"; printf '%s' "$findings" > "$SD/$NAME.last-findings"
        else log "brain unreachable: heartbeat not delivered (local heartbeat file is current)"; fi
      fi
    fi
  fi
}

while :; do
  halted && { log "drain $NAME: stop file; exiting"; exit 0; }
  [ -f "$ENABLED" ] || { log "drain $NAME: switched off; exiting"; exit 0; }
  CYC_ELIGIBLE=0; CYC_HELD=0; CYC_MERGED=0; CYC_OLDEST_HELD=0
  cycle; crc=$?
  heartbeat "$crc"
  [ "$ONCE" = 1 ] && exit 0
  sleep "$INTERVAL"
done
