#!/usr/bin/env bash
#
# auto-fix-check.sh — shared CI watchdog for Force AI Suite.
# Polls GitHub for failed CI runs across FWB/WBS/CRM in the last ~30 min.
# For each NEW failure (not seen in state file), invokes `claude -p` to
# investigate + propose a fix as a PR. Pings Telegram with the result.
#
# Called from three places:
#   - Layer A: in-session CronCreate (Claude Code REPL while open)
#   - Layer B: launchd plist  (~/Library/LaunchAgents/com.ahmadsharaf.auto-fix.plist)
#   - Layer C: GitHub Actions auto-fix-watchdog.yml (cloud-side escalation only)
#
# Safety:
#   - Never pushes to main directly. Only opens PRs.
#   - Won't re-process a failure already seen (idempotent via state file).
#   - Holds a lockfile so concurrent invocations from A+B don't collide.
#   - STATE PRECHECK: before investigating, skips failures already resolved
#     (branch SHA superseded, latest run green/in-flight, PR merged/closed,
#     or an auto-fix/* branch — loop guard). Prevents redundant/harmful PRs.
#   - WORKTREE ISOLATION: each fix runs in a throwaway git worktree based on
#     the failing commit (~/Desktop/projects/_worktrees/<repo>__autofix-<sha>),
#     never the shared root checkout — so it can't switch a root's branch under
#     a concurrent interactive session (parallel-session-worktree rule).
#   - SECURITY GUARDRAILS: the claude -p prompt forbids weakening auth/MFA,
#     gaming tests/gates, or hardcoding away config toggles; it reports instead
#     of opening a PR when the only fix would violate a constraint.
#
# State: ~/.claude/auto-fix-state.json
#   { "ebda-store": "12345", "ebda-whatsapp": "67890", ... }

set -uo pipefail
# CLAUDE_BIN lets a test point this at a stub. Without it the model call is
# untestable offline, which is why none of the OS's 17 model-calling scripts
# had a single behavioural test. Defaults to the real CLI.
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
. "$(dirname "$0")/lib/os-state.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-state.sh" 2>/dev/null || true
. "$(dirname "$0")/lib/autofix-coord.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/autofix-coord.sh" 2>/dev/null || true
. "$(dirname "$0")/lib/autonomy.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/autonomy.sh" 2>/dev/null || true

# TCC canary (2026-07-12): abort when the launchd context cannot see ~/Desktop
OS_JOB_NAME=auto-fix-check
if command -v require_projects_access >/dev/null 2>&1; then require_projects_access || exit 0; fi


# ---------------------- Config ----------------------
# repo:workflow_filename — per-repo because WBS uses pr-validation.yml, others use ci.yml
REPOS=(
  "Ebda-AI-Studio/ebda-store:ci.yml"
  "Ebda-AI-Studio/ebda-whatsapp:pr-validation.yml"
  "Ebda-AI-Studio/ebda-studio:ci.yml"
)
STATE_FILE="$HOME/.claude/auto-fix-state.json"
LOCK_DIR="/tmp/auto-fix-check.lock.d"
LOG_FILE="$HOME/Library/Logs/auto-fix.log"

# ---------------------- Circuit breaker (Rule 3 in feedback-six-failures-from-2026-05-26) ----------------------
# Without these caps, the auto-fix system can cascade: a failure opens a fix
# PR → merge fires CI → CI fails (different reason) → open another fix PR →
# snowball not convergence. On 2026-05-26 this burned ~600 GH Actions minutes
# in 48h across 3 repos.
#
# MAX_PR_PER_DAY: hard cap on auto-fix PRs opened per UTC day (across all
#                 repos combined). Once hit, the system goes dormant until
#                 the next day, sending a single Telegram to flag.
# MAX_PR_PER_SHA: prevent stacking multiple fix PRs against the same SHA
#                 (already enforced via the EXISTING_PR check below, but
#                 documented here for completeness).
MAX_PR_PER_DAY=3
MAX_PR_PER_SHA=1

# Sentinel file: when present, auto-fix is administratively paused regardless
# of caps. Manual override for when Ahmad is debugging a known issue and
# doesn't want the system fighting him. To pause: `touch ~/.claude/auto-fix-paused`.
# To resume: `rm ~/.claude/auto-fix-paused`.
PAUSE_SENTINEL="$HOME/.claude/auto-fix-paused"
# 720min (12h) covers overnight scenarios. Once a run_id is processed it goes
# in the state file and won't re-fire, so the cap exists only to prevent
# spamming fixes for truly ancient (>12h) failures that are presumed already
# triaged manually.
# Was 30min initially → dead zone where C escalated but A skipped.
# Was 240min next → still too narrow (278min ≈ "just merged 5h ago" missed).
LOOKBACK_MIN=720
# Telegram creds live in a local env file (chmod 600, never committed). They were hard-coded
# defaults here until 2026-10-08; that token sits in git history and must be rotated.
TG_ENV="${TG_ENV:-${OS_SERVICES_ENV:-$HOME/.whisky-services.env}}"
# shellcheck source=/dev/null
[ -f "$TG_ENV" ] && { set -a; . "$TG_ENV"; set +a; }
: "${TELEGRAM_BOT_TOKEN:?TELEGRAM_BOT_TOKEN unset — put it in $TG_ENV}"
: "${TELEGRAM_ALERT_CHAT_ID:?TELEGRAM_ALERT_CHAT_ID unset — put it in $TG_ENV}"

mkdir -p "$(dirname "$LOG_FILE")"

# ---------------------- Helpers ----------------------
log() {
  echo "[$(date '+%Y-%m-%dT%H:%M:%S')] $*" | tee -a "$LOG_FILE" >&2
}

send_telegram() {
  local msg="$1"
  curl -sS -m 10 -X POST \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d chat_id="${TELEGRAM_ALERT_CHAT_ID}" \
    -d parse_mode=Markdown \
    -d disable_web_page_preview=true \
    -d text="$msg" >/dev/null || log "telegram send failed"
}

get_last_processed() {
  local repo="$1"
  if [[ -f "$STATE_FILE" ]]; then
    jq -r --arg r "$repo" '.[$r] // "0"' "$STATE_FILE" 2>/dev/null || echo "0"
  else
    echo "0"
  fi
}

set_last_processed() {
  local repo="$1"
  local run_id="$2"
  if [[ ! -f "$STATE_FILE" ]]; then echo "{}" > "$STATE_FILE"; fi
  local tmp; tmp=$(mktemp)
  jq --arg r "$repo" --arg id "$run_id" '.[$r] = $id' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

command -v wr_claim >/dev/null 2>&1 || { log "REGISTRY UNAVAILABLE — coordination libs failed to source; aborting to avoid uncoordinated action"; exit 3; }

# ---------------------- Lock (macOS-compatible — flock not available) ----------------------
# Atomic mkdir trick: succeeds only if the dir doesn't exist.
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  # Check if the lock is stale (>30 min — assume crashed process)
  if [[ -d "$LOCK_DIR" ]]; then
    LOCK_AGE=$(( ($(date +%s) - $(stat -c %Y "$LOCK_DIR" 2>/dev/null || stat -f %m "$LOCK_DIR" 2>/dev/null || echo "$(date +%s)")) / 60 ))
    if (( LOCK_AGE > 30 )); then
      log "stale lock (${LOCK_AGE}min) — clearing"
      rm -rf "$LOCK_DIR"
      mkdir "$LOCK_DIR"
    else
      log "another auto-fix-check is running (lock held ${LOCK_AGE}min); exiting"
      exit 0
    fi
  fi
fi
# Release lock on exit (success OR error)
trap 'rm -rf "$LOCK_DIR"' EXIT

log "=== auto-fix-check starting ==="

autonomy_is_off && { log "autonomy frozen (/kill) — skipping auto-fix run"; exit 0; }

# ---------------------- Circuit breaker checks ----------------------
# Pause sentinel first — overrides everything.
if [[ -f "$PAUSE_SENTINEL" ]]; then
  log "PAUSED — sentinel file $PAUSE_SENTINEL present. exiting without action."
  exit 0
fi

# Daily PR cap. State stored as `.daily_count.<UTC-date>` (jq path) so we
# auto-rotate per day without manual reset.
TODAY=$(date -u +%Y-%m-%d)
DAILY_COUNT=0
if [[ -f "$STATE_FILE" ]]; then
  DAILY_COUNT=$(jq -r --arg d "$TODAY" '.daily_count[$d] // 0' "$STATE_FILE" 2>/dev/null || echo 0)
fi
if (( DAILY_COUNT >= MAX_PR_PER_DAY )); then
  log "DAILY CAP REACHED ($DAILY_COUNT/$MAX_PR_PER_DAY auto-fix PRs opened today UTC). exiting."
  # Only send one notification per day per UTC date — track the warning sent flag too.
  WARNED=$(jq -r --arg d "$TODAY" '.daily_warned[$d] // false' "$STATE_FILE" 2>/dev/null || echo false)
  if [[ "$WARNED" != "true" ]]; then
    send_telegram "🛑 *Auto-fix dormant* — daily cap (\`$MAX_PR_PER_DAY\` PRs) reached for $TODAY UTC. Manual triage from here. Resumes at 00:00 UTC tomorrow."
    tmp=$(mktemp)
    jq --arg d "$TODAY" '.daily_warned[$d] = true' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
  fi
  exit 0
fi
log "daily auto-fix budget: $DAILY_COUNT / $MAX_PR_PER_DAY used today (UTC $TODAY)"

# Helper to increment the daily counter after a successful PR open.
increment_daily_count() {
  if [[ ! -f "$STATE_FILE" ]]; then echo "{}" > "$STATE_FILE"; fi
  local tmp; tmp=$(mktemp)
  jq --arg d "$TODAY" '.daily_count[$d] = (.daily_count[$d] // 0) + 1' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

# ---------------------- Per-repo check ----------------------
for REPO_ENTRY in "${REPOS[@]}"; do
  [ -n "${AUTOFIX_ONLY_REPO:-}" ] && [ "${REPO_ENTRY%:*}" != "$AUTOFIX_ONLY_REPO" ] && continue
  REPO="${REPO_ENTRY%:*}"           # "Ebda-AI-Studio/foo"
  WORKFLOW="${REPO_ENTRY#*:}"        # "ci.yml" or "pr-validation.yml"
  log "checking $REPO (workflow=$WORKFLOW)"
  LAST_ID=$(get_last_processed "$REPO")

  # Get the latest CI workflow run that completed with failure in the lookback window.
  FAILED_RUN=$(gh run list \
    --repo "$REPO" \
    --workflow="$WORKFLOW" \
    --status=failure \
    --limit=1 \
    --json databaseId,headSha,headBranch,conclusion,createdAt,displayTitle 2>/dev/null \
    | jq -r '.[0] // {}')

  RUN_ID=$(echo "$FAILED_RUN" | jq -r '.databaseId // empty')
  HEAD_SHA=$(echo "$FAILED_RUN" | jq -r '.headSha // empty')
  HEAD_BRANCH=$(echo "$FAILED_RUN" | jq -r '.headBranch // empty')
  TITLE=$(echo "$FAILED_RUN" | jq -r '.displayTitle // empty')
  CREATED=$(echo "$FAILED_RUN" | jq -r '.createdAt // empty')

  if [[ -z "$RUN_ID" ]]; then
    log "  no failed CI runs"
    continue
  fi

  # Check if we already processed this one
  if [[ "$RUN_ID" == "$LAST_ID" ]]; then
    log "  already processed run $RUN_ID — skipping"
    continue
  fi

  # Check if it's recent enough (skip ancient failures)
  # createdAt is ISO 8601 UTC. Compare to current UTC minus LOOKBACK_MIN.
  # No GNU-date (gdate) dependency: it is Homebrew coreutils and is NOT on the
  # launchd PATH, so the job's behaviour depended on who launched it. BSD date
  # parses the Z-suffixed stamp (TZ=UTC: createdAt is UTC, -j -f would otherwise
  # read it as local time); GNU date (-d) is the fallback on Linux.
  RUN_EPOCH=$(TZ=UTC /bin/date -j -f "%Y-%m-%dT%H:%M:%SZ" "${CREATED}" "+%s" 2>/dev/null \
              || date -d "$CREATED" "+%s" 2>/dev/null \
              || echo "0")
  NOW_EPOCH=$(date "+%s")
  AGE_MIN=$(( (NOW_EPOCH - RUN_EPOCH) / 60 ))

  if (( AGE_MIN > LOOKBACK_MIN )); then
    log "  failure too old (${AGE_MIN}min > ${LOOKBACK_MIN}min) — marking processed without action"
    set_last_processed "$REPO" "$RUN_ID"
    continue
  fi

  log "  NEW FAILURE: run=$RUN_ID sha=${HEAD_SHA:0:8} branch=${HEAD_BRANCH:-?} age=${AGE_MIN}min title=\"$TITLE\""

  # ---------- State precheck: don't fix what's already resolved ----------
  # The #1 cause of redundant/harmful auto-fix PRs is acting on a failure that
  # another commit, run, or session has already addressed. Before spending a
  # claude -p investigation, confirm the failure is still live & worth fixing.
  # All checks fail-OPEN on lookup error (proceed) EXCEPT positive "resolved"
  # signals, which fail-SAFE (skip). Verified-stale cases here: WBS #36 (cloud
  # already active), FWB #79's E2E (already fixed properly in a merged PR).

  # Resolve the PR (if any) for the failing head branch BEFORE claiming, so the
  # claim uses the SAME canonical key babysit-prs uses (pr:<slug>#<n>) instead
  # of the plain ci:<slug>@<sha> key — otherwise the two responders can act on
  # the same PR concurrently without ever seeing each other's claim. Empty when
  # no PR exists yet (autofix_workid falls back to the ci: key). Per-repo like
  # $HEAD_SHA; stays in scope through every wr_release in this iteration.
  PRNUM=""
  if [[ -n "$HEAD_BRANCH" ]]; then
    PRNUM=$(gh pr list --repo "$REPO" --head "$HEAD_BRANCH" --json number --jq '.[0].number // empty' 2>/dev/null)
  fi

  # Coordination gate: skip if a live session (e.g. babysit-prs) already owns
  # this exact ci:<repo>@<sha> (or, once a PR exists, pr:<repo>#<n>) work item.
  # Claimed here (not marked processed — a later pass re-evaluates once the
  # other owner releases it); released on every exit path below once claimed,
  # so a claim never leaks past this repo's processing (success or fail).
  if ! autofix_claim_gate "$REPO" "$HEAD_SHA" "autofix" "$PRNUM"; then
    log "  skip $REPO@$HEAD_SHA — already owned by $(wr_owner "$(autofix_workid "$REPO" "$HEAD_SHA" "$PRNUM")")"
    continue
  fi

  # (a) Loop guard: never auto-fix the auto-fixer's own branches.
  if [[ "$HEAD_BRANCH" == auto-fix/* ]]; then
    log "  branch is an auto-fix branch ($HEAD_BRANCH) — not fixing the fixer; skipping"
    set_last_processed "$REPO" "$RUN_ID"
    wr_release "$(autofix_workid "$REPO" "$HEAD_SHA" "$PRNUM")" "autofix"
    continue
  fi

  if [[ -n "$HEAD_BRANCH" ]]; then
    # (b) Superseded SHA: the branch has moved past the commit that failed.
    CUR_HEAD=$(gh api "repos/$REPO/commits/$HEAD_BRANCH" -q '.sha' 2>/dev/null || echo "")
    if [[ -n "$CUR_HEAD" && "$CUR_HEAD" != "$HEAD_SHA" ]]; then
      log "  SHA superseded (branch head ${CUR_HEAD:0:8} != failed ${HEAD_SHA:0:8}) — skipping"
      set_last_processed "$REPO" "$RUN_ID"
      wr_release "$(autofix_workid "$REPO" "$HEAD_SHA" "$PRNUM")" "autofix"
      continue
    fi

    # (c) Already green / being retested: latest run on this branch is success
    #     or still in flight. Re-running CI may have cleared a flake, or another
    #     session pushed a real fix.
    LATEST_ON_BRANCH=$(gh run list --repo "$REPO" --branch "$HEAD_BRANCH" --limit 1 \
                        --json status,conclusion 2>/dev/null \
                        | jq -r '.[0] | "\(.status):\(.conclusion // "-")"' 2>/dev/null || echo "")
    case "$LATEST_ON_BRANCH" in
      completed:success)
        log "  branch '$HEAD_BRANCH' latest run is SUCCESS — failure already resolved; skipping"
        set_last_processed "$REPO" "$RUN_ID"
        wr_release "$(autofix_workid "$REPO" "$HEAD_SHA" "$PRNUM")" "autofix"
        continue
        ;;
      queued:*|in_progress:*|requested:*|waiting:*|pending:*)
        log "  branch '$HEAD_BRANCH' has a run in flight ($LATEST_ON_BRANCH) — deferring to it; skipping this pass"
        # NOT marked processed: re-evaluate next pass once the in-flight run settles.
        wr_release "$(autofix_workid "$REPO" "$HEAD_SHA" "$PRNUM")" "autofix"
        continue
        ;;
    esac

    # (d) Associated PR already merged/closed: nothing to fix.
    PR_STATE=$(gh pr list --repo "$REPO" --state all --head "$HEAD_BRANCH" --limit 1 \
                --json state -q '.[0].state // empty' 2>/dev/null || echo "")
    if [[ "$PR_STATE" == "MERGED" || "$PR_STATE" == "CLOSED" ]]; then
      log "  PR for '$HEAD_BRANCH' is $PR_STATE — skipping"
      set_last_processed "$REPO" "$RUN_ID"
      wr_release "$(autofix_workid "$REPO" "$HEAD_SHA" "$PRNUM")" "autofix"
      continue
    fi
  fi

  # Check if a fix PR already exists for this SHA
  # Use --head to match the EXACT branch name. Previous version used
  # --search which OR-matches words — returned any PR with "auto-fix" in
  # title/body/branch, blocking new fixes once ONE auto-fix PR was open.
  # Bug verified 2026-05-25: PR #3 (auto-fix/de6870db) blocked auto-fix
  # for failure on 341dffb9.
  EXISTING_PR=$(gh pr list --repo "$REPO" --state=open --head "auto-fix/${HEAD_SHA:0:8}" --json number 2>/dev/null \
                | jq -r '.[0].number // empty')
  if [[ -n "$EXISTING_PR" ]]; then
    log "  auto-fix PR #$EXISTING_PR already exists for ${HEAD_SHA:0:8} — skipping"
    set_last_processed "$REPO" "$RUN_ID"
    wr_release "$(autofix_workid "$REPO" "$HEAD_SHA" "$PRNUM")" "autofix"
    continue
  fi

  # ---------- Dispatch claude -p for investigation + PR ----------
  REPO_SHORT=$(basename "$REPO")
  case "$REPO_SHORT" in
    ebda-store) LOCAL_PATH="$HOME/Desktop/projects/Ebda-AI-Studio/internal-projects/ebda-store" ;;
    ebda-whatsapp)  LOCAL_PATH="$HOME/Desktop/projects/Ebda-AI-Studio/internal-projects/ebda-whatsapp" ;;
    ebda-studio)       LOCAL_PATH="$HOME/Desktop/projects/Ebda-AI-Studio/internal-projects/ebda-studio" ;;
    *) LOCAL_PATH="$HOME/Desktop/projects/$REPO_SHORT" ;;
  esac

  if [[ ! -d "$LOCAL_PATH/.git" ]]; then
    log "  local repo missing ($LOCAL_PATH) — sending telegram alert only"
    send_telegram "⚠️ Auto-fix can't investigate \`$REPO\` failure \`${HEAD_SHA:0:8}\` — local clone missing at $LOCAL_PATH"
    set_last_processed "$REPO" "$RUN_ID"
    wr_release "$(autofix_workid "$REPO" "$HEAD_SHA" "$PRNUM")" "autofix"
    continue
  fi

  # Verify daily cap once more right before dispatch — another concurrent
  # invocation may have raced ahead since the top-of-script check.
  CURRENT_COUNT=$(jq -r --arg d "$TODAY" '.daily_count[$d] // 0' "$STATE_FILE" 2>/dev/null || echo 0)
  if (( CURRENT_COUNT >= MAX_PR_PER_DAY )); then
    log "  daily cap hit mid-loop ($CURRENT_COUNT) — skipping $REPO without dispatching"
    set_last_processed "$REPO" "$RUN_ID"
    wr_release "$(autofix_workid "$REPO" "$HEAD_SHA" "$PRNUM")" "autofix"
    continue
  fi

  # ---------- Isolated worktree (NEVER touch the shared root checkout) ----------
  # The root (`$LOCAL_PATH`) is used ONLY as the git management dir; its branch
  # is never switched. Each fix runs in a throwaway worktree based on the exact
  # commit that failed, so concurrent interactive sessions + this watchdog can't
  # collide on one checkout (the parallel-session-worktree-orchestration rule).
  AUTOFIX_BRANCH="auto-fix/${HEAD_SHA:0:8}"
  WT="$HOME/Desktop/projects/_worktrees/${REPO_SHORT}__autofix-${HEAD_SHA:0:8}"
  BASE_REF="${HEAD_BRANCH:-main}"

  # Scrub any leftovers from a prior aborted run for this SHA.
  git -C "$LOCAL_PATH" worktree remove "$WT" --force 2>/dev/null || true
  git -C "$LOCAL_PATH" branch -D "$AUTOFIX_BRANCH" 2>/dev/null || true
  git -C "$LOCAL_PATH" worktree prune 2>/dev/null || true

  git -C "$LOCAL_PATH" fetch origin "$BASE_REF" -q 2>/dev/null || git -C "$LOCAL_PATH" fetch origin -q 2>/dev/null || true
  mkdir -p "$HOME/Desktop/projects/_worktrees"
  if ! git -C "$LOCAL_PATH" worktree add -b "$AUTOFIX_BRANCH" "$WT" "$HEAD_SHA" >>"$LOG_FILE" 2>&1; then
    log "  worktree create failed (sha ${HEAD_SHA:0:8}) — telegram report only"
    send_telegram "⚠️ Auto-fix couldn't create an isolated worktree for \`$REPO\` \`${HEAD_SHA:0:8}\`. Needs manual triage."
    git -C "$LOCAL_PATH" worktree prune 2>/dev/null || true
    set_last_processed "$REPO" "$RUN_ID"
    wr_release "$(autofix_workid "$REPO" "$HEAD_SHA" "$PRNUM")" "autofix"
    continue
  fi

  send_telegram "🔧 Auto-fix investigating \`$REPO\` failure \`${HEAD_SHA:0:8}\` (isolated worktree). PR link incoming."

  # Headless claude. The prompt forbids weakening any security control (the
  # MFA-bypass class), forbids gaming tests/gates, and keeps config toggles
  # intact. If the only possible fix violates a constraint, it reports instead.
  PROMPT="You are in a clean, isolated git worktree at $WT, already checked out on branch '$AUTOFIX_BRANCH', based on the exact commit that failed CI (${HEAD_SHA:0:8} on branch '$BASE_REF' of $REPO). Do NOT cd elsewhere, switch branches, or touch any other checkout.

TASK: Fix the CI failure from run $RUN_ID (title: \"$TITLE\"). Investigate with 'gh run view $RUN_ID --repo $REPO --log-failed', find the root cause, make the smallest focused fix.

HARD CONSTRAINTS (absolute — if a fix would require violating ANY of these, do NOT make it; instead Telegram a short report of the failure + why it can't be safely auto-fixed, then stop without opening a PR):
- NEVER disable, bypass, weaken, or stub authentication, authorization, MFA/2FA, or any password/token check — including in tests. A test failing because it doesn't complete MFA must be fixed by completing MFA correctly, never by bypassing it.
- NEVER delete, comment out, weaken, or trivially short-circuit a test assertion to make it pass.
- NEVER edit gitleaks/secret-scan allowlists, .gitleaksignore, or any security CI gate to hide a finding; NEVER lower an audit/severity threshold to pass.
- NEVER push to main/master; NEVER hardcode away a configurable runner/env toggle (keep USE_SELF_HOSTED-style expressions intact).
- Skip (report only) if the failure is in a third-party dependency or is purely env/config.

WHEN THE FIX IS READY: stage with 'git add <specific paths>' (NEVER 'git add -A'), lowercase conventional-commit message, push '$AUTOFIX_BRANCH', then open a PR with base branch '$BASE_REF' describing what failed, the fix, and how you verified it. Finally Telegram the PR URL via https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage to chat ${TELEGRAM_ALERT_CHAT_ID}."

  (
    cd "$WT"
    # Headless: skip interactive prompts so claude can run gh/git to open the
    # PR. Trusted context (Ahmad's machine + own repos); the HARD CONSTRAINTS
    # above + daily cap + isolated worktree bound the blast radius.
    "$CLAUDE_BIN" -p --dangerously-skip-permissions "$PROMPT" >> "$LOG_FILE" 2>&1
    EXIT=$?
    log "  claude -p exit: $EXIT"
  )

  # Tear down the worktree. The fix branch lives on the remote (if a PR was
  # opened); the local branch + worktree dir are disposable.
  git -C "$LOCAL_PATH" worktree remove "$WT" --force 2>/dev/null || true
  git -C "$LOCAL_PATH" branch -D "$AUTOFIX_BRANCH" 2>/dev/null || true
  git -C "$LOCAL_PATH" worktree prune 2>/dev/null || true

  # claude -p may or may not have actually opened a PR (e.g. it might have
  # decided the failure is third-party / unsafe-to-fix + just sent Telegram).
  # Verify a PR exists for this SHA before counting against the daily cap.
  POST_PR=$(gh pr list --repo "$REPO" --state=open --head "$AUTOFIX_BRANCH" --json number 2>/dev/null | jq -r '.[0].number // empty')
  if [[ -n "$POST_PR" ]]; then
    increment_daily_count
    log "  auto-fix PR #$POST_PR opened; daily count now $((CURRENT_COUNT + 1))/$MAX_PR_PER_DAY"
  else
    log "  no PR opened by claude -p — daily count not incremented"
  fi

  set_last_processed "$REPO" "$RUN_ID"
  wr_release "$(autofix_workid "$REPO" "$HEAD_SHA" "$PRNUM")" "autofix"
done

log "=== auto-fix-check done ==="
