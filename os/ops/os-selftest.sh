#!/usr/bin/env bash
# ============================================================
# Whisky AI OS — os-selftest.sh  (OS self-integration test)
#
# Proves the OS works end-to-end and alerts on the OS's OWN failure:
#   (a) PLIST FRESHNESS — every scheduled launchd job ran within its expected
#       window (checks StandardOutPath log mtime OR launchctl loaded state).
#       A stale / never-run job → a finding.
#   (b) SYNTHETIC ROUND-TRIP — writes a fake 9-field findings array to a temp
#       file, runs findings-normalize.py --json, asserts the path is alive.
#   (c) DREAM-FIX ORPHAN GUARD — detects auto-fix/* and dream-fix/* git
#       branches / worktrees across $OS_PROJECTS_DIR with NO open PR.
#       Known unfixed watchdog bug; each orphan surfaces as a finding.
#
# Bus writes:
#   write_status "os-selftest"  ok/warn  summary  detailJSON
#   emit_event   "os-selftest"  sev      summary
#   emit_inbox                  summary  detail    ← ONLY if the OS itself is broken
#
# Usage:
#   ops/os-selftest.sh             # full check, no notification
#   ops/os-selftest.sh --notify    # same + Telegram if failures found
#   DRY_RUN=1 ops/os-selftest.sh   # check without writing state
#
# Deps: bash 3.2+, python3 (stdlib). gh / launchctl optional (fail-open).
# ============================================================
# shellcheck source=lib/os-config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/os-config.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-config.sh" 2>/dev/null || true
command -v os_config_load >/dev/null 2>&1 && os_config_load
set -uo pipefail
cd "$(dirname "$0")" || exit 1

. ./lib/os-state.sh 2>/dev/null || true
# Per-job freshness verdicts (which in turn source lib/job-cadence.sh for the
# real cadence). Checked below rather than assumed: without it every freshness
# verdict would be a "command not found" that this script's own `|| true` style
# would swallow, and the section would report nothing at all while looking fine.
. ./lib/job-freshness.sh 2>/dev/null || . "$HOME/.claude/scripts/lib/job-freshness.sh" 2>/dev/null || true
# The backup project list + pause rule, shared with the backup jobs so the
# checker cannot watch a narrower fleet than the writer writes.
. ./lib/backup-projects.sh 2>/dev/null || . "$HOME/.claude/scripts/lib/backup-projects.sh" 2>/dev/null || true
# G14: a job that exits non-zero opens a deduped review-finding issue with its log tail
. ./lib/job-failure.sh 2>/dev/null || . "$HOME/.claude/scripts/lib/job-failure.sh" 2>/dev/null || true

DRY_RUN="${DRY_RUN:-0}"
NOTIFY=0
for a in "$@"; do
  case "$a" in --notify) NOTIFY=1 ;; esac
done

STATE_DIR="$HOME/.whisky-os-state"; mkdir -p "$STATE_DIR"
# plists live in the repo ops/launchd; the installed copy has none — fall back
# to the foundation checkout, then to the ACTUALLY-LOADED LaunchAgents (2026-07-12:
# the freshness check silently skipped when run from ~/.claude/scripts).
LAUNCHD_DIR="$(pwd)/launchd"
[ -d "$LAUNCHD_DIR" ] || LAUNCHD_DIR="$OS_HOME/os/ops/launchd"
[ -d "$LAUNCHD_DIR" ] || LAUNCHD_DIR="$HOME/Library/LaunchAgents"
PROJECTS="$OS_PROJECTS_DIR"
NORMALIZE_LIB="./lib/findings-normalize.py"

# ── helpers ─────────────────────────────────────────────────────────────────
_now_iso() { python3 -c "import datetime; print(datetime.datetime.now().isoformat(timespec='seconds'))"; }
_info()     { printf '%s\n' "$*"; }
_now_epoch(){ python3 -c "import time; print(int(time.time()))"; }

# Plain indexed arrays (bash 3.2 safe — no associative arrays)
findings_critical=()
findings_high=()
findings_medium=()
findings_low=()
findings_info=()

add_critical() { findings_critical+=("CRITICAL: $1"); }
add_high()     { findings_high+=("HIGH: $1"); }
add_medium()   { findings_medium+=("MEDIUM: $1"); }
add_low()      { findings_low+=("LOW: $1"); }
add_info()     { findings_info+=("INFO: $1"); }

_info ""
_info "Whisky AI OS — os-selftest"
_info "Started: $(_now_iso)"
[ "$DRY_RUN" = "1" ] && _info "(DRY_RUN=1 — no state write)"
_info ""

PASS=0; FAIL=0
FAILED_CHECKS=()
# Record WHICH check failed, not just how many. On 2026-08-18 the daily brief
# reported "PASS=46 FAIL=1" and the next run was clean — the failure was
# transient and left NO record of what broke, so it could not be diagnosed at
# all. A count alone is not a signal you can act on.
_fail() { FAIL=$(( FAIL + 1 )); FAILED_CHECKS+=("$1"); }

# TCC canary — the health checker REPORTS blindness instead of aborting:
# a blind context must show up as a CRITICAL finding, and all ~/Desktop-based
# checks (orphan-guard, artifact freshness) are skipped as unknowable.
DESKTOP_VISIBLE=1
if command -v require_projects_access >/dev/null 2>&1 && ! require_projects_access 2>/dev/null; then
  DESKTOP_VISIBLE=0
  add_critical "TCC-BLIND: this context cannot read $OS_PROJECTS_DIR — repo/artifact checks skipped; scheduled jobs guarded by the canary are aborting safely. Fix: Full Disk Access for /bin/bash."
  _fail "TCC-BLIND: cannot read $OS_PROJECTS_DIR"
fi

# ─────────────────────────────────────────────────────────────────────────────
# (a) PLIST FRESHNESS — check every scheduled launchd job ran within its window
# ─────────────────────────────────────────────────────────────────────────────
_info "--- (a) PLIST FRESHNESS ---"

NOW_EPOCH="$(_now_epoch)"

# FAIL LOUD if the verdict library is missing. Failing open here would silently
# retire the entire freshness section: every job would be skipped and the digest
# would still print "PASS: n FAIL: 0", which is precisely the shape of gate this
# whole file exists to catch.
FRESHNESS_LIB_OK=1
if ! command -v job_freshness_verdict >/dev/null 2>&1; then
  FRESHNESS_LIB_OK=0
  add_critical "lib/job-freshness.sh is missing, so NO scheduled job's freshness was checked at all (run ops/install.sh)"
  _fail "lib/job-freshness.sh missing — freshness section did not run"
fi

# The verdict itself lives in lib/job-freshness.sh, which asks lib/job-cadence.sh
# for the job's REAL cadence instead of re-deriving one here. This function used
# to carry its own inline plist parser ("Weekday present -> weekly, else daily"),
# which could not see Day, Month, an ARRAY of calendar entries, or a bogus
# StartInterval of 0/true — so session-mining (Day=1, MONTHLY) was treated as a
# DAILY job. Two parsers for one fact is how they drift; there is now one.
#
# Keeping the decision in a library also makes it TESTABLE. The old logic was
# welded into this rendering function, so os-selftest.test.sh "covered" it by
# reimplementing `window = cadence*2 + 3600` in python and asserting that copy —
# green regardless of what the shipped code did.
check_plist_freshness() {
  local plist="$1"
  [ -f "$plist" ] || return 0
  local label; label=$(basename "$plist" .plist)

  local v; v="$(job_freshness_verdict "$plist" "$NOW_EPOCH")"
  local verdict age window period log_path
  verdict="${v%%|*}"; v="${v#*|}"
  age="${v%%|*}";     v="${v#*|}"
  window="${v%%|*}";  v="${v#*|}"
  period="${v%%|*}";  log_path="${v#*|}"

  case "$verdict" in
    fresh)
      add_info "$label: log fresh (${age}s ago, window=${window}s, cadence=${period}s)"
      PASS=$(( PASS + 1 )) ;;

    slept)
      # Host slept through the job's window; the job has had no post-wake slot yet.
      add_info "$label: log ${age}s old but the host woke less than one period (${period}s) ago — not yet due after sleep"
      PASS=$(( PASS + 1 )) ;;

    stale)
      add_medium "$label: log stale — last run ${age}s ago, expected within ${window}s (cadence ${period}s)"
      _fail "$label: log stale (last run ${age}s ago)" ;;

    # A daemon has no cadence, so its log mtime is evidence of NOTHING — a
    # healthy resident process can sit silent for weeks. Liveness is the only
    # honest test. ${OS_LAUNCHD_PREFIX}.dashboard used to be `continue`d out of this loop
    # entirely, i.e. checked by nothing, which reads as a pass.
    daemon-running)
      add_info "$label: daemon alive (KeepAlive/RunAtLoad, no cadence — judged by process liveness)"
      PASS=$(( PASS + 1 )) ;;
    daemon-stopped)
      add_high "$label: daemon is NOT running — launchd should keep it resident (KeepAlive/RunAtLoad) but no live process exists."
      _fail "$label: daemon not running" ;;
    daemon-unprovable)
      # launchctl absent (Linux CI). Genuinely unknown, so it scores no PASS —
      # but it is not a defect in the job, so it is not a FAIL either.
      add_low "$label: daemon, but launchctl is unavailable here — liveness could not be proven." ;;

    # Neither a determinable cadence nor a liveness artifact: this job can never
    # be shown to have run OR to have stopped. That is a config defect, and
    # reporting it is the whole point — the alternative is a check that passes
    # because there was nothing it could ever look at.
    unprovable)
      add_medium "$label: no determinable cadence and no liveness artifact — freshness can never be proven (fix the plist: give it StartInterval/StartCalendarInterval, or KeepAlive, or a StandardOutPath)"
      _fail "$label: unprovable — no cadence and no artifact" ;;

    # launchd creates StandardOutPath when it spawns a job, so an absent file
    # means the job has not run since that path was set. Graded, not uniform: for
    # most jobs that is a LOW note, but for a BACKUP job it means the backup has
    # never produced output, which is the incident itself.
    never-ran)
      case "$label" in
        "${OS_LAUNCHD_PREFIX}.ebda-cf-backup")
          add_high "$label: loaded, but its declared log does not exist ($log_path) — this backup has never produced output. Treat as NOT running."
          _fail "$label: declared log absent — backup has never run" ;;
        *)
          add_low "$label: loaded, but its declared log does not exist yet ($log_path) — being registered is not evidence that it ran." ;;
      esac ;;

    # A job cannot be late before its first scheduled slot. session-mining is
    # MONTHLY (Day=1); flagging it from the day it is installed is noise that
    # trains everyone to ignore this section. Self-limiting: once the plist
    # outlives one full period the suppression stops on its own.
    awaiting-first-run)
      add_info "$label: no log yet, but its plist is only ${age}s old against a ${period}s cadence — it cannot be late before its first slot." ;;

    not-loaded)
      # A job unloaded BY the pause is not an unregistered job — ops/msg-power.sh
      # unloads msg-monitor deliberately, and resume reloads it.
      case "$label" in
        "${OS_LAUNCHD_PREFIX}.msg-monitor")
          service_paused msg 2>/dev/null && { _info "$label: SKIPPED — unloaded by the whatsapp pause"; return 0; } ;;
      esac
      add_medium "$label: not loaded in launchctl and no log found — job may be unregistered"
      _fail "$label: not loaded in launchctl and no log" ;;

    *)
      add_low "$label: could not parse plist (skipping freshness check)" ;;
  esac
  return 0
}

# G14: last exit code of each loaded job; non-zero -> add_medium + (not on DRY_RUN) a deduped review-finding issue
check_last_exit() {
  local plist="$1" label rc out
  command -v jf_last_exit >/dev/null 2>&1 || return 0
  label=$(basename "$plist" .plist)
  rc="$(jf_last_exit "$label")"
  [ -n "$rc" ] && [ "$rc" != "0" ] || return 0
  add_medium "$label: last run exited non-zero (code $rc)"
  _fail "$label: last exit code $rc"
  if [ "$DRY_RUN" != "1" ] && command -v job_failure_report >/dev/null 2>&1; then
    out="$(job_failure_report "$label" "$rc" "$plist")"
    _info "  fixer: $out"
  fi
}

if [ "$FRESHNESS_LIB_OK" = "0" ]; then
  _info "plist freshness: SKIPPED — lib/job-freshness.sh unavailable (reported as CRITICAL above)"
elif [ -d "$LAUNCHD_DIR" ]; then
  for plist in "$LAUNCHD_DIR"/${OS_LAUNCHD_PREFIX}.*.plist; do
    [ -f "$plist" ] || continue
    # Skip this self-test's own plist (expected not to have run yet after first install)
    label=$(basename "$plist" .plist)
    [ "$label" = "${OS_LAUNCHD_PREFIX}.os-selftest" ] && continue
    # NOTE: ${OS_LAUNCHD_PREFIX}.dashboard used to be skipped here as an "on-demand job
    # with no cadence". It is a KeepAlive daemon, and it is now checked for
    # process liveness like every other daemon. A job excluded from the only
    # loop that inspects it is not passing; it is unobserved.
    check_plist_freshness "$plist"
    check_last_exit "$plist"
  done
else
  add_low "launchd dir not found at $LAUNCHD_DIR — skipping freshness check"
fi

_info ""

# ─────────────────────────────────────────────────────────────────────────────
# (b) SYNTHETIC FINDING ROUND-TRIP  (proves scan→normalize path is alive)
# ─────────────────────────────────────────────────────────────────────────────
_info "--- (b) SYNTHETIC ROUND-TRIP ---"

WORK_DIR=$(mktemp -d /tmp/os-selftest-XXXXXX 2>/dev/null || mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

SYNTH_FILE="$WORK_DIR/synth-findings.json"

python3 - "$SYNTH_FILE" <<'PY'
import json, sys
# 9-field schema (matches the Live Companion OS finding contract)
findings = [
    {
        "repo":        "os-selftest",
        "class":       "synthetic",
        "severity":    "low",
        "file":        "ops/os-selftest.sh",
        "line":        1,
        "title":       "synthetic self-test finding alpha",
        "detail":      "injected by os-selftest to verify the normalize path",
        "fix":         "no action needed — this is a test probe",
        "autofixable": False,
    },
    {
        "repo":        "os-selftest",
        "class":       "synthetic",
        "severity":    "low",
        "file":        "ops/os-selftest.sh",
        "line":        2,
        "title":       "synthetic self-test finding alpha",  # same root-cause → should group
        "detail":      "second instance for grouping test",
        "fix":         "no action needed",
        "autofixable": False,
    },
    {
        "repo":        "os-selftest",
        "class":       "synthetic",
        "severity":    "medium",
        "file":        "ops/os-selftest.sh",
        "line":        3,
        "title":       "synthetic self-test finding beta",
        "detail":      "distinct root cause",
        "fix":         "no action needed",
        "autofixable": False,
    },
]
json.dump(findings, open(sys.argv[1], 'w'), indent=2)
print('wrote %d synthetic findings to %s' % (len(findings), sys.argv[1]))
PY

_info "  wrote synthetic findings to $SYNTH_FILE"

NORMALIZE_OK=0
NORM_JSON="$WORK_DIR/norm-out.json"
if [ -f "$NORMALIZE_LIB" ]; then
  python3 "$NORMALIZE_LIB" "$SYNTH_FILE" --json > "$NORM_JSON" 2>/dev/null || true
  if [ -s "$NORM_JSON" ]; then
    # Assert: grouped count == 2 (alpha×2 grouped into 1 + beta = 2), raw == 3
    # Pass the result via a temp file (avoids shell-quoting issues with large JSON)
    NORM_CHECK=$(python3 "$WORK_DIR/norm-check.py" "$NORM_JSON" 2>/dev/null || echo "fail")
    # Write the check script to a temp file (heredoc in a subshell is bash 3.2 safe)
    python3 - "$WORK_DIR/norm-check.py" <<'PY' 2>/dev/null || true
import sys
code = '''
import json, sys
result = json.load(open(sys.argv[1]))
grouped = result.get("grouped", [])
counts  = result.get("counts", {})
raw     = counts.get("raw", 0)
grp     = counts.get("grouped", 0)
if raw != 3:
    print("fail: expected raw=3, got %d" % raw)
elif grp != 2:
    print("fail: expected grouped=2, got %d" % grp)
elif not any(g.get("count", 1) == 2 for g in grouped):
    print("fail: expected one group with count=2 (alpha*2 merged)")
else:
    print("ok")
'''
open(sys.argv[1], 'w').write(code)
PY
    NORM_CHECK=$(python3 "$WORK_DIR/norm-check.py" "$NORM_JSON" 2>/dev/null || echo "fail")
    if [ "$NORM_CHECK" = "ok" ]; then
      NORMALIZE_OK=1
      add_info "round-trip: normalize path alive — 3 raw → 2 grouped (grouping verified)"
      PASS=$(( PASS + 1 ))
      _info "  round-trip: PASS (3 raw → 2 grouped)"
    else
      add_critical "round-trip: normalize path BROKEN — $NORM_CHECK"
      _fail "round-trip: normalize path BROKEN"
      _info "  round-trip: FAIL — $NORM_CHECK"
    fi
  else
    add_critical "round-trip: findings-normalize.py produced no output (crashed or missing)"
    _fail "round-trip: normalize produced no output"
    _info "  round-trip: FAIL — normalize produced no output"
  fi
else
  add_critical "round-trip: findings-normalize.py not found at $NORMALIZE_LIB"
  _fail "round-trip: normalize library missing"
  _info "  round-trip: FAIL — normalize library missing"
fi

_info ""

# ─────────────────────────────────────────────────────────────────────────────
# (c) DREAM-FIX ORPHAN GUARD
# ─────────────────────────────────────────────────────────────────────────────
_info "--- (c) DREAM-FIX ORPHAN GUARD ---"

ORPHAN_COUNT=0

if command -v git >/dev/null 2>&1 && command -v gh >/dev/null 2>&1; then
  # Collect all git repos under $OS_PROJECTS_DIR (top-level only, not worktrees)
  while IFS= read -r repo_dir; do
    [ -d "$repo_dir/.git" ] || continue
    repo_name=$(basename "$repo_dir")

    # Get all local + remote branches matching the orphan pattern
    branch_list=$(git -C "$repo_dir" branch -a 2>/dev/null \
      | grep -E '(auto-fix/|dream-fix/)' \
      | sed 's|remotes/[^/]*/||' \
      | sed 's/^[[:space:]]*//' \
      | sort -u 2>/dev/null || true)

    if [ -z "$branch_list" ]; then continue; fi

    while IFS= read -r branch; do
      [ -z "$branch" ] && continue
      # Check if there's an open PR for this branch
      # slug from the remote URL — dir name ≠ repo slug (ebda-whatsapp
      # → ebda-whatsapp, ebda-studio → ebda-studio; 2026-07-12)
      repo_slug=$(git -C "$repo_dir" remote get-url origin 2>/dev/null | sed -E 's#.*github.com[:/]##; s#\.git$##')
      [ -n "$repo_slug" ] || repo_slug="$OS_ORG/$repo_name"
      pr_state=$(_ut "$OS_UT_FAST" gh pr list --head "$branch" --repo "$repo_slug" \
        --state open --json number --jq 'length' 2>/dev/null || echo "skip")
      if [ "$pr_state" = "skip" ]; then
        add_low "orphan-guard: $repo_name/$branch — gh unavailable for this repo (skipping)"
        continue
      fi
      if [ "$pr_state" = "0" ] || [ -z "$pr_state" ]; then
        add_medium "orphan-guard: $repo_name/$branch — no open PR (known dream-fix watchdog bug)"
        ORPHAN_COUNT=$(( ORPHAN_COUNT + 1 ))
        _fail "orphan-guard: $repo_name/$branch — no open PR"
      else
        add_info "orphan-guard: $repo_name/$branch — has open PR ($pr_state)"
        PASS=$(( PASS + 1 ))
      fi
    done <<EOF_BRANCHES
$branch_list
EOF_BRANCHES

  done < <(PROJECTS_ROOT="$PROJECTS" list_repo_roots)   # the one enumerator (lib/projects-layout.sh)

  # Also check git worktrees across all repo dirs
  while IFS= read -r repo_dir; do
    [ -d "$repo_dir/.git" ] || continue
    repo_name=$(basename "$repo_dir")
    wt_list=$(git -C "$repo_dir" worktree list --porcelain 2>/dev/null \
      | grep '^branch ' \
      | grep -E '(auto-fix/|dream-fix/)' \
      | sed 's|^branch refs/heads/||' || true)
    if [ -z "$wt_list" ]; then continue; fi
    while IFS= read -r wt_branch; do
      [ -z "$wt_branch" ] && continue
      pr_state=$(_ut "$OS_UT_FAST" gh pr list --head "$wt_branch" --repo "$OS_ORG/$repo_name" \
        --state open --json number --jq 'length' 2>/dev/null || echo "skip")
      if [ "$pr_state" = "skip" ]; then
        add_low "orphan-guard: worktree $repo_name/$wt_branch — gh unavailable (skipping)"
        continue
      fi
      if [ "$pr_state" = "0" ] || [ -z "$pr_state" ]; then
        add_medium "orphan-guard: worktree $repo_name/$wt_branch — no open PR (orphaned worktree)"
        ORPHAN_COUNT=$(( ORPHAN_COUNT + 1 ))
        _fail "orphan-guard: worktree $repo_name/$wt_branch — no open PR"
      fi
    done <<EOF_WT
$wt_list
EOF_WT
  done < <(PROJECTS_ROOT="$PROJECTS" list_repo_roots)

  if [ "$ORPHAN_COUNT" -eq 0 ]; then
    add_info "orphan-guard: no orphaned auto-fix/dream-fix branches found"
    PASS=$(( PASS + 1 ))
    _info "  orphan-guard: PASS — no orphans"
  else
    _info "  orphan-guard: FAIL — $ORPHAN_COUNT orphan(s)"
  fi
elif ! command -v git >/dev/null 2>&1; then
  add_low "orphan-guard: git not available — skipping"
  _info "  orphan-guard: SKIP (no git)"
else
  # gh not available — check branches only (no PR lookup)
  _info "  orphan-guard: gh not available — scanning branches without PR check"
  while IFS= read -r repo_dir; do
    [ -d "$repo_dir/.git" ] || continue
    repo_name=$(basename "$repo_dir")
    branch_list=$(git -C "$repo_dir" branch -a 2>/dev/null \
      | grep -E '(auto-fix/|dream-fix/)' \
      | sed 's|remotes/[^/]*/||' \
      | sed 's/^[[:space:]]*//' \
      | sort -u 2>/dev/null || true)
    if [ -n "$branch_list" ]; then
      while IFS= read -r branch; do
        [ -z "$branch" ] && continue
        add_low "orphan-guard: $repo_name/$branch found (gh unavailable — no PR status)"
        ORPHAN_COUNT=$(( ORPHAN_COUNT + 1 ))
      done <<EOF_NOGR
$branch_list
EOF_NOGR
    fi
  done < <(PROJECTS_ROOT="$PROJECTS" list_repo_roots)
  if [ "$ORPHAN_COUNT" -eq 0 ]; then
    add_info "orphan-guard: no auto-fix/dream-fix branches found (gh not available)"
    PASS=$(( PASS + 1 ))
    _info "  orphan-guard: PASS — no branches (gh unavailable)"
  else
    _info "  orphan-guard: INFO — $ORPHAN_COUNT branch(es) found but cannot verify PR status"
  fi
fi

_info ""

# ─────────────────────────────────────────────────────────────────────────────
# (e) LEARNING-LOOP OUTPUT — assert the continuous-learning chain produces
# artifacts, not just exit-0 jobs. Added 2026-07-11: the whole chain (jq path →
# blank traces → CLI crash) was dead for weeks while every stage exited cleanly.
# Check the OUTPUT: fresh non-blank traces + a non-empty instinct store.
# ─────────────────────────────────────────────────────────────────────────────
_info "checking learning-loop output (traces + instinct store) ..."
INSTINCTS="$HOME/.claude/instincts"
fresh_traces=$(find "$INSTINCTS/traces" -maxdepth 1 -name '*.trace' -mtime -2 2>/dev/null | head -5)
if [ -n "$fresh_traces" ]; then
  # a healthy trace line has 4 tab-separated fields; blank cwd/tool = broken
  # logger. Sessions predating a logger fix leave blank traces behind, so only
  # flag when NO fresh trace is healthy (tail = the most recent lines).
  good_trace=$(tail -q -n 3 $fresh_traces 2>/dev/null | awk -F'\t' 'NF>=3 && $2!="" && $3!="" {print; exit}')
  if [ -z "$good_trace" ]; then
    add_high "learning-loop: every fresh trace has blank fields — instinct-log.sh jq extraction is broken again"
    _fail "learning-loop: every fresh trace has blank fields"
  else
    PASS=$(( PASS + 1 ))
  fi
else
  add_medium "learning-loop: no trace written in 48h — PostToolUse hook not firing (check settings.json + instinct-log.sh)"
  _fail "learning-loop: no trace written in 48h"
fi
store_lines=$(wc -l < "$INSTINCTS/store.jsonl" 2>/dev/null | tr -d ' ' || echo 0)
store_age_ok=$(find "$INSTINCTS/store.jsonl" -mtime -8 2>/dev/null)
if [ "${store_lines:-0}" -eq 0 ]; then
  add_medium "learning-loop: instinct store is EMPTY — extractor has never distilled anything (check extract.log for CLI crashes / node version)"
  _fail "learning-loop: instinct store is EMPTY"
elif [ -z "$store_age_ok" ]; then
  add_low "learning-loop: instinct store untouched >8d — extractor may be skipping every run"
else
  PASS=$(( PASS + 1 ))
fi
_info ""

# ─────────────────────────────────────────────────────────────────────────────
# (f) ARTIFACT FRESHNESS — jobs must produce OUTPUT, not just exit 0 (the
# learning-loop lesson generalized, 2026-07-12): assert each producer's
# artifact exists, is non-trivial, and is fresher than its cadence allows.
# ─────────────────────────────────────────────────────────────────────────────
if [ "$DESKTOP_VISIBLE" = "0" ]; then _info "artifact freshness: SKIPPED (TCC-blind)"; else
_info "checking artifact freshness (backups / dream / graphify) ..."
# daily managed-db backups: newest dump per project < 36h old and not truncated.
#
# The watched set is DERIVED from lib/backup-projects.sh — the same list the dump
# job iterates — so the checker can no longer watch a SUBSET of what the writer
# writes. It did exactly that until 2026-09-19: this loop named
# ebda-store and ebda-whatsapp while the job dumped six
# projects, so other projects could have stopped being backed
# up indefinitely with every gate green. A project dumped by a different
# job, in a different managed Postgres account) was watched by nothing at all.
BK="$OS_PROJECTS_DIR/_backups"
if ! command -v backup_watch_names >/dev/null 2>&1; then
  add_high "artifact: lib/backup-projects.sh is missing, so the dump freshness of EVERY project went unchecked (run ops/install.sh)"
  _fail "artifact: backup project list unavailable — dump freshness unchecked"
else
for proj in $(backup_watch_names); do
  # A parked project is deliberately skipped by the dump job, so it CANNOT
  # have a fresh dump — flagging it HIGH every run puts a permanent FAIL floor
  # on the OS health check and trains everyone to read FAIL as normal. Nothing is
  # writing to it either, so the pre-pause dump still represents the data exactly.
  if backup_project_paused "$proj"; then
    _info "artifact: $proj SKIPPED — paused on purpose (ops/msg-power.sh status)"
    continue
  fi
  # Age in hours of the newest non-truncated dump. Computed with python3, NOT
  # `find -mtime -36h`: the `h` suffix is a BSD extension that GNU find rejects
  # outright, so the moment this runs anywhere but macOS (the cloud tier, or CI)
  # the find errors, returns nothing, and reports every project stale.
  #
  # The size floor is 1KB, not the 10KB this check used to carry. Measured
  # 2026-09-19: ebda-studio's healthy nightly dump is 5,059 bytes and
  # another project's is 6,684 — both perfectly valid, both permanently below a
  # 10KB floor, so widening the watch list to every project would have created a
  # permanent two-FAIL floor on day one. Size is the WRONG test for validity
  # anyway, and it is already done properly where the data is in hand:
  # the dump job counted actual COPY rows and fails when rows < tables (the
  # check that would have caught the 2026-08-02 CRM schema-only disaster). This
  # floor only has to reject a truncated or empty .gz; freshness is its job.
  newest_age_h=$(BKP="$BK/$proj" python3 -c '
import glob, os, time
best = None
for p in glob.glob(os.path.join(os.environ["BKP"], "*.sql.gz")):
    try:
        st = os.stat(p)
    except OSError:
        continue
    if st.st_size <= 1024:
        continue
    age = (time.time() - st.st_mtime) / 3600.0
    if best is None or age < best:
        best = age
print("" if best is None else "%.1f" % best)
' 2>/dev/null)
  if [ -n "$newest_age_h" ] && [ "${newest_age_h%%.*}" -lt 36 ] 2>/dev/null; then
    PASS=$(( PASS + 1 ))
  else
    add_high "artifact: no fresh managed Postgres dump for $proj in 36h (${OS_LAUNCHD_PREFIX}.db-backup output check)"
    _fail "artifact: no fresh managed Postgres dump for $proj in 36h"
  fi
done
fi
# nightly dream cycle: findings json touched < 48h ago and parseable
DREAM="$HOME/.whisky-os-state/dream-findings.json"
if [ -n "$(find "$DREAM" -mtime -2 2>/dev/null)" ] && python3 -c "import json;json.load(open('$DREAM'))" 2>/dev/null; then
  PASS=$(( PASS + 1 ))
else
  add_medium "artifact: dream-findings.json stale (>48h) or unparseable — dream cycle producing nothing"
  FAIL=$(( FAIL + 1 ))
fi
# graphify global graph: refreshed < 8d ago
if [ -n "$(find "$HOME/.graphify/global-graph.json" -mtime -8 2>/dev/null)" ]; then
  PASS=$(( PASS + 1 ))
else
  add_low "artifact: global graphify graph untouched >8d — memory pipeline may be skipping the graph step"
fi
fi
_info ""

# ─────────────────────────────────────────────────────────────────────────────
# Human digest
# ─────────────────────────────────────────────────────────────────────────────
_info "========================================"
_info "  OS SELF-TEST RESULTS"
_info "  $(_now_iso)"
_info "========================================"
_info ""
_info "  PASS: $PASS   FAIL: $FAIL"
_info ""

all_findings=()
for f in "${findings_critical[@]+"${findings_critical[@]}"}"; do all_findings+=("$f"); done
for f in "${findings_high[@]+"${findings_high[@]}"}"; do all_findings+=("$f"); done
for f in "${findings_medium[@]+"${findings_medium[@]}"}"; do all_findings+=("$f"); done
for f in "${findings_low[@]+"${findings_low[@]}"}"; do all_findings+=("$f"); done

if [ "${#all_findings[@]}" -gt 0 ]; then
  _info "  Findings:"
  for f in ${all_findings[@]+"${all_findings[@]}"}; do
    _info "    • $f"
  done
else
  _info "  All checks passed. OS appears healthy."
fi

for f in "${findings_info[@]+"${findings_info[@]}"}"; do
  _info "    ↳ $f"
done
_info ""

# ─────────────────────────────────────────────────────────────────────────────
# Projects layout — every repo in its business-folder slot (2026-09-25).
# A rule only in CLAUDE.md is a preference; this is the gate. Declared pending
# moves (lib/projects-layout.pending.tsv) report but do not fail.
# ─────────────────────────────────────────────────────────────────────────────
if [ -x ./projects-layout-check.sh ]; then
  if _layout_out=$(bash ./projects-layout-check.sh 2>&1); then
    PASS=$(( PASS + 1 ))
  else
    _fail "projects-layout: $(printf '%s' "$_layout_out" | grep -c '^MISPLACED') repo(s) outside their slot — run projects-layout-check.sh"
  fi
  # Same class, other side: a script naming a project path that no longer exists
  # scans nothing and still "passes". Checked against the installed scripts (this dir).
  if _refs_out=$(bash ./projects-layout-check.sh --refs . 2>&1); then
    PASS=$(( PASS + 1 ))
  else
    _fail "projects-layout: $(printf '%s' "$_refs_out" | grep -c '^DEAD') dead project path(s) in OS scripts — run projects-layout-check.sh --refs"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# Bus writes
# ─────────────────────────────────────────────────────────────────────────────
CRITICAL_COUNT=${#findings_critical[@]}
HIGH_COUNT=${#findings_high[@]}
MEDIUM_COUNT=${#findings_medium[@]}
ORPHAN_STR="$ORPHAN_COUNT"

SUMMARY_MSG="os-selftest: PASS=$PASS FAIL=$FAIL orphans=$ORPHAN_STR normalize=$NORMALIZE_OK"
FAILED_JSON="$(printf '%s\n' "${FAILED_CHECKS[@]+"${FAILED_CHECKS[@]}"}" \
  | python3 -c "import sys,json;print(json.dumps([l for l in sys.stdin.read().split(chr(10)) if l.strip()]))" 2>/dev/null || echo '[]')"
[ -n "$FAILED_JSON" ] || FAILED_JSON='[]'
DETAIL_JSON="{\"pass\":$PASS,\"fail\":$FAIL,\"orphans\":$ORPHAN_STR,\"normalize_ok\":$NORMALIZE_OK,\"critical\":$CRITICAL_COUNT,\"high\":$HIGH_COUNT,\"failed\":$FAILED_JSON}"

if [ "$DRY_RUN" != "1" ]; then
  if command -v write_status >/dev/null 2>&1; then
    if [ "$FAIL" -gt 0 ]; then
      write_status "os-selftest" "warn" "$SUMMARY_MSG" "$DETAIL_JSON"
    else
      write_status "os-selftest" "true" "$SUMMARY_MSG" "$DETAIL_JSON"
    fi
  fi

  if command -v emit_event >/dev/null 2>&1; then
    if [ "$CRITICAL_COUNT" -gt 0 ] || [ "$HIGH_COUNT" -gt 0 ]; then
      emit_event "os-selftest" "high" "$SUMMARY_MSG" "$DETAIL_JSON"
    elif [ "$FAIL" -gt 0 ]; then
      emit_event "os-selftest" "medium" "$SUMMARY_MSG" "$DETAIL_JSON"
    else
      emit_event "os-selftest" "info" "$SUMMARY_MSG" "$DETAIL_JSON"
    fi
  fi

  # emit_inbox ONLY when the OS itself is broken: normalize dead OR critical findings
  if command -v emit_inbox >/dev/null 2>&1; then
    if [ "$NORMALIZE_OK" = "0" ] || [ "$CRITICAL_COUNT" -gt 0 ]; then
      emit_inbox "OS self-test FAILED — normalize path broken or critical findings. PASS=$PASS FAIL=$FAIL" \
        "$DETAIL_JSON"
    fi
  fi
fi

if [ "$NOTIFY" = "1" ] && [ "$FAIL" -gt 0 ] && [ -x ./notify.sh ]; then
  ./notify.sh "os-selftest: $FAIL failure(s) — PASS=$PASS orphans=$ORPHAN_STR normalize=$NORMALIZE_OK. Check os-selftest-status.json." 2>/dev/null || true
fi

# Always exit 0 — a self-test must NEVER crash the fleet
exit 0
