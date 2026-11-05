#!/usr/bin/env bash
# propagate.sh — Whisky AI OS cross-repo propagation engine.
#
# WHY: when a cross-cutting improvement lands in one Force repo (a CI/workflow
# file, a security gate, a shared standard), this tool opens the SAME change as
# a human-gated PR across every OTHER applicable Force repo, so all repos stay
# at the same standard without Ahmad doing it N times.
#
# SAFETY GUARANTEE:
#   - Default mode = DRY-RUN: prints the plan only, never writes/commits/pushes.
#   - --apply mode: creates a branch + PR per target repo; NEVER merges; NEVER
#     force-pushes; NEVER touches main directly. Human reviews and merges every PR.
#   - Degrades gracefully: missing checkout, no remote, identical content → SKIP.
#
# Usage:
#   ops/propagate.sh <source-repo> <path-glob>                   # dry-run (default)
#   ops/propagate.sh <source-repo> <path-glob> --apply           # open PRs
#   ops/propagate.sh <source-repo> <path-glob> --apply --branch <name> --title <t>
#
# Examples:
#   ops/propagate.sh ebda-store ".gitleaks.toml"
#   ops/propagate.sh ebda-store ".github/workflows/gitleaks.yml" --apply
#   ops/propagate.sh ebda-store ".github/workflows/gitleaks.yml" \
#       --apply --branch propagate/gitleaks-2026 --title "chore: propagate gitleaks config"
#
# Repos (GitHub org: $OS_ORG/ plus personal): ebda-store, ebda-whatsapp, ebda-studio, mypovonai, digital-card
# Local checkout dir aliases: see local_dir() (identity unless a dir name differs from the GitHub slug).
#
# Requirements: bash >=3.2 (macOS default), python3, gh, git
#
# Exit codes:
#   0 — completed (even if some repos were skipped)
#   1 — fatal: bad args, no source files found, missing tools

# shellcheck source=lib/os-config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/os-config.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-config.sh" 2>/dev/null || true
command -v os_config_load >/dev/null 2>&1 && os_config_load
set -uo pipefail
. "$(dirname "$0")/lib/os-state.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-state.sh" 2>/dev/null || true

# TCC canary (2026-07-12): abort when the launchd context cannot see ~/Desktop
OS_JOB_NAME=propagate
if command -v require_projects_access >/dev/null 2>&1; then require_projects_access || exit 0; fi


HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE" || exit 1
STATE_DIR="$HOME/.whisky-os-state"; mkdir -p "$STATE_DIR"
GH_USER="$OS_ORG"
PROJECTS_ROOT="$OS_PROJECTS_DIR"
NEW_WORKTREE_HELPER="$HOME/.claude/scripts/new-task-worktree.sh"

# ---------------------------------------------------------------------------
# Bash 3.2-safe: NO associative arrays, NO mapfile/readarray.
# Repo metadata encoded in functions using case statements.
# ---------------------------------------------------------------------------

# all_repos: prints every repo slug (one per line), excluding the source
# We filter out the source repo in the main loop, not here.
all_repos() {
  printf '%s\n' \
    ebda-store \
    ebda-whatsapp \
    ebda-studio \
    mypovonai \
    digital-card
}

# local_dir <gh-slug>: maps GitHub slug -> local checkout dir name
local_dir() {
  case "$1" in
    *)                     echo "$1" ;;
  esac
}

# local_path <gh-slug>: full local path to repo checkout
local_path() {
  resolve_repo_dir "$(local_dir "$1")" 2>/dev/null || echo "$PROJECTS_ROOT/$(local_dir "$1")"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
if [ "${#}" -lt 2 ]; then
  echo "usage: propagate.sh <source-repo> <path-glob> [--apply] [--branch <name>] [--title <t>]" >&2
  exit 1
fi

SOURCE_SLUG="$1"
PATH_GLOB="$2"
shift 2

APPLY=0
CUSTOM_BRANCH=""
CUSTOM_TITLE=""

while [ "${#}" -gt 0 ]; do
  case "$1" in
    --apply)          APPLY=1 ;;
    --branch)         shift; CUSTOM_BRANCH="${1:-}" ;;
    --title)          shift; CUSTOM_TITLE="${1:-}" ;;
    --)               shift; break ;;
    *)                echo "propagate: unknown flag: $1" >&2; exit 1 ;;
  esac
  shift
done

# ---------------------------------------------------------------------------
# Tool checks
# ---------------------------------------------------------------------------
command -v python3 >/dev/null || { echo "propagate: python3 missing" >&2; exit 1; }
command -v git     >/dev/null || { echo "propagate: git missing"     >&2; exit 1; }
if [ "$APPLY" = "1" ]; then
  command -v gh >/dev/null || { echo "propagate: gh CLI missing (required for --apply)" >&2; exit 1; }
fi

# ---------------------------------------------------------------------------
# Resolve source files
# ---------------------------------------------------------------------------
SOURCE_LOCAL="$(local_path "$SOURCE_SLUG")"
if [ ! -d "$SOURCE_LOCAL" ]; then
  echo "propagate: source checkout not found: $SOURCE_LOCAL" >&2; exit 1
fi

# Collect matching source files (bash 3.2-safe glob expansion)
SOURCE_FILES=""
# Use find with glob patterns — supports both exact paths and patterns
if echo "$PATH_GLOB" | grep -q '[*?[]'; then
  # It's a real glob — use find
  SOURCE_FILES="$(find "$SOURCE_LOCAL" -maxdepth 4 -path "$SOURCE_LOCAL/$PATH_GLOB" 2>/dev/null | sort)"
else
  # Exact path
  if [ -f "$SOURCE_LOCAL/$PATH_GLOB" ]; then
    SOURCE_FILES="$SOURCE_LOCAL/$PATH_GLOB"
  fi
fi

if [ -z "$SOURCE_FILES" ]; then
  echo "propagate: no source files found matching '$PATH_GLOB' in $SOURCE_LOCAL" >&2
  exit 1
fi

echo "propagate: source repo: $SOURCE_SLUG"
echo "propagate: source path: $PATH_GLOB"
echo "propagate: source files found:"
while IFS= read -r sf; do
  # Print relative path
  rel="${sf#$SOURCE_LOCAL/}"
  echo "  $rel"
done <<EOF
$SOURCE_FILES
EOF
echo ""

# ---------------------------------------------------------------------------
# Mode banner
# ---------------------------------------------------------------------------
if [ "$APPLY" = "0" ]; then
  echo "=== DRY-RUN MODE (no branch/push/PR will be created) ==="
  echo "    Pass --apply to open PRs."
  echo ""
fi

# ---------------------------------------------------------------------------
# Compute a default branch name from the path glob (date-scoped, safe chars)
# ---------------------------------------------------------------------------
_sanitize_branch() {
  # Lower, replace non-alphanumeric with -, collapse, strip leading/trailing -
  echo "$1" | python3 -c "
import sys,re
s=sys.stdin.read().strip().lower()
s=re.sub(r'[^a-z0-9]+','-',s)
s=s.strip('-')
print(s[:50])
"
}

DATESTAMP="$(date +%Y%m%d)"
if [ -n "$CUSTOM_BRANCH" ]; then
  PROP_BRANCH="$CUSTOM_BRANCH"
else
  BRANCH_SAFE="$(_sanitize_branch "$PATH_GLOB")"
  PROP_BRANCH="propagate/${BRANCH_SAFE}-${DATESTAMP}"
fi

if [ -n "$CUSTOM_TITLE" ]; then
  PR_TITLE="$CUSTOM_TITLE"
else
  PR_TITLE="chore: propagate ${PATH_GLOB} from ${SOURCE_SLUG} (${DATESTAMP})"
fi

# ---------------------------------------------------------------------------
# Per-target evaluation (the main loop)
# ---------------------------------------------------------------------------
# Statuses:
#   IDENTICAL   — already at same content, nothing to do
#   APPLICABLE  — target has the file and it differs
#   NEW-FILE    — target doesn't have the file yet (by default: SKIP — path not present)
#   SKIP-NODIR  — checkout not found locally
#   SKIP-NOGIT  — not a git repo / no origin remote
#   SKIP-NOGITREMOTE  — local repo exists but no github remote found

COL_REPO=30
COL_STATUS=14

printf "%-${COL_REPO}s  %-${COL_STATUS}s  %s\n" "REPO" "STATUS" "DETAIL"
printf "%-${COL_REPO}s  %-${COL_STATUS}s  %s\n" "$(printf '%0.s-' $(seq 1 $COL_REPO))" "$(printf '%0.s-' $(seq 1 $COL_STATUS))" "-----------------------------"

APPLICABLE_REPOS=""   # space-separated list of slugs with applicable diffs
SKIP_REASONS=""       # newline-separated "slug: reason" summaries
TOTAL_APPLICABLE=0
TOTAL_IDENTICAL=0
TOTAL_SKIP=0

while IFS= read -r target_slug; do
  # Skip the source repo itself
  if [ "$target_slug" = "$SOURCE_SLUG" ]; then
    continue
  fi

  TARGET_LOCAL="$(local_path "$target_slug")"

  # Check: local checkout present
  if [ ! -d "$TARGET_LOCAL" ]; then
    printf "%-${COL_REPO}s  %-${COL_STATUS}s  %s\n" "$target_slug" "SKIP-NODIR" "local checkout not found at $TARGET_LOCAL"
    TOTAL_SKIP=$((TOTAL_SKIP + 1))
    continue
  fi

  # Check: is a git repo with a remote we can push to
  if ! git -C "$TARGET_LOCAL" rev-parse --git-dir >/dev/null 2>&1; then
    printf "%-${COL_REPO}s  %-${COL_STATUS}s  %s\n" "$target_slug" "SKIP-NOGIT" "not a git repo"
    TOTAL_SKIP=$((TOTAL_SKIP + 1))
    continue
  fi

  ORIGIN_URL="$(git -C "$TARGET_LOCAL" remote get-url origin 2>/dev/null || echo "")"
  if [ -z "$ORIGIN_URL" ]; then
    printf "%-${COL_REPO}s  %-${COL_STATUS}s  %s\n" "$target_slug" "SKIP-NOREMOTE" "no origin remote configured"
    TOTAL_SKIP=$((TOTAL_SKIP + 1))
    continue
  fi

  # Evaluate each source file against the target
  # For a multi-file glob we assess per-file, then summarize at the repo level
  REPO_HAS_DIFF=0
  REPO_ALL_IDENTICAL=0
  REPO_FILE_COUNT=0
  REPO_DIFF_DETAIL=""

  while IFS= read -r sf; do
    rel="${sf#$SOURCE_LOCAL/}"
    target_file="$TARGET_LOCAL/$rel"
    REPO_FILE_COUNT=$((REPO_FILE_COUNT + 1))

    if [ ! -f "$target_file" ]; then
      # Target doesn't have this file — SKIP (applicability rule: only propagate where path exists)
      REPO_DIFF_DETAIL="${REPO_DIFF_DETAIL}${rel}:NOT-PRESENT "
    else
      # Compare content
      if diff -q "$sf" "$target_file" >/dev/null 2>&1; then
        REPO_ALL_IDENTICAL=$((REPO_ALL_IDENTICAL + 1))
        REPO_DIFF_DETAIL="${REPO_DIFF_DETAIL}${rel}:identical "
      else
        REPO_HAS_DIFF=1
        # Compute a diffstat-style summary (pass diff output via argv[1] to avoid stdin conflict)
        _DIFF_TEXT="$(diff -u "$target_file" "$sf" 2>/dev/null || true)"
        _PY_DIFFSTAT='import sys; lines=sys.argv[1].split("\n"); add=sum(1 for l in lines if l.startswith("+") and not l.startswith("+++")); rem=sum(1 for l in lines if l.startswith("-") and not l.startswith("---")); print("+%d/-%d"%(add,rem))'
        DIFFSTAT="$(python3 -c "$_PY_DIFFSTAT" "$_DIFF_TEXT" 2>/dev/null || echo "differs")"
        REPO_DIFF_DETAIL="${REPO_DIFF_DETAIL}${rel}:${DIFFSTAT} "
      fi
    fi
  done <<EOF
$SOURCE_FILES
EOF

  # Determine overall repo status
  # Count how many files are NOT-PRESENT (all missing = skip entire repo)
  NOT_PRESENT_COUNT="$(echo "$REPO_DIFF_DETAIL" | python3 -c "
import sys
s=sys.stdin.read()
print(s.count(':NOT-PRESENT'))
" 2>/dev/null || echo 0)"

  if [ "$REPO_HAS_DIFF" = "1" ]; then
    STATUS="APPLICABLE"
    TOTAL_APPLICABLE=$((TOTAL_APPLICABLE + 1))
    # Trim trailing space from detail
    DETAIL="$(echo "$REPO_DIFF_DETAIL" | python3 -c "import sys; print(sys.stdin.read().strip())" 2>/dev/null)"
    printf "%-${COL_REPO}s  %-${COL_STATUS}s  %s\n" "$target_slug" "$STATUS" "$DETAIL"
    APPLICABLE_REPOS="${APPLICABLE_REPOS}${target_slug} "
  elif [ "$REPO_ALL_IDENTICAL" -gt 0 ] && [ "$REPO_FILE_COUNT" = "$REPO_ALL_IDENTICAL" ]; then
    STATUS="IDENTICAL"
    TOTAL_IDENTICAL=$((TOTAL_IDENTICAL + 1))
    printf "%-${COL_REPO}s  %-${COL_STATUS}s  %s\n" "$target_slug" "$STATUS" "already at same content"
  else
    STATUS="SKIP"
    TOTAL_SKIP=$((TOTAL_SKIP + 1))
    printf "%-${COL_REPO}s  %-${COL_STATUS}s  %s\n" "$target_slug" "$STATUS" "no applicable files at this path"
  fi

done <<EOF
$(all_repos)
EOF

echo ""
printf "Summary: %d APPLICABLE, %d IDENTICAL (no-op), %d SKIPPED\n" \
  "$TOTAL_APPLICABLE" "$TOTAL_IDENTICAL" "$TOTAL_SKIP"

# ---------------------------------------------------------------------------
# Dry-run exit
# ---------------------------------------------------------------------------
if [ "$APPLY" = "0" ]; then
  echo ""
  if [ "$TOTAL_APPLICABLE" -gt 0 ]; then
    echo "DRY-RUN: Would open PRs in: $APPLICABLE_REPOS"
    echo "         Branch: $PROP_BRANCH"
    echo "         Title:  $PR_TITLE"
    echo "         Re-run with --apply to create branches and open PRs (human merges)."
  else
    echo "DRY-RUN: No repos need updating — nothing to propagate."
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# --apply mode: for each applicable repo, create worktree, copy, commit, PR
# ---------------------------------------------------------------------------
if [ "$TOTAL_APPLICABLE" = "0" ]; then
  echo ""
  echo "propagate: nothing to do — no applicable repos differ."
  exit 0
fi

echo ""
echo "=== APPLY MODE: opening PRs ==="
echo "Branch: $PROP_BRANCH"
echo "Title:  $PR_TITLE"
echo ""

OPENED_PRS=""
FAILED_REPOS=""

for target_slug in $APPLICABLE_REPOS; do
  TARGET_LOCAL="$(local_path "$target_slug")"
  TARGET_DIR_NAME="$(local_dir "$target_slug")"

  echo "--- $target_slug ---"

  # Determine worktree path
  BRANCH_SLUG="$(echo "$PROP_BRANCH" | tr '/' '-')"
  WT_PATH="$PROJECTS_ROOT/_worktrees/${TARGET_DIR_NAME}__${BRANCH_SLUG}"

  # Create worktree using helper if available, else raw git
  if [ -x "$NEW_WORKTREE_HELPER" ]; then
    echo "  creating worktree via new-task-worktree.sh..."
    if ! "$NEW_WORKTREE_HELPER" "$TARGET_DIR_NAME" "$PROP_BRANCH" 2>&1 | sed 's/^/  /'; then
      echo "  WARN: new-task-worktree.sh failed — attempting raw git worktree add"
      git -C "$TARGET_LOCAL" fetch origin main -q 2>&1 | sed 's/^/  /'
      if git -C "$TARGET_LOCAL" show-ref --verify --quiet "refs/heads/$PROP_BRANCH"; then
        git -C "$TARGET_LOCAL" worktree add "$WT_PATH" "$PROP_BRANCH" 2>&1 | sed 's/^/  /'
      else
        git -C "$TARGET_LOCAL" worktree add "$WT_PATH" -b "$PROP_BRANCH" origin/main 2>&1 | sed 's/^/  /'
      fi
    fi
  else
    echo "  creating worktree via git worktree add..."
    git -C "$TARGET_LOCAL" fetch origin main -q 2>&1 | sed 's/^/  /'
    if git -C "$TARGET_LOCAL" show-ref --verify --quiet "refs/heads/$PROP_BRANCH"; then
      git -C "$TARGET_LOCAL" worktree add "$WT_PATH" "$PROP_BRANCH" 2>&1 | sed 's/^/  /'
    else
      git -C "$TARGET_LOCAL" worktree add "$WT_PATH" -b "$PROP_BRANCH" origin/main 2>&1 | sed 's/^/  /'
    fi
  fi

  if [ ! -d "$WT_PATH" ]; then
    echo "  ERROR: worktree not created at $WT_PATH — skipping $target_slug"
    FAILED_REPOS="${FAILED_REPOS}${target_slug}(worktree-failed) "
    continue
  fi

  # Copy source files into worktree
  COPIED_FILES=""
  COPY_FAILED=0
  while IFS= read -r sf; do
    rel="${sf#$SOURCE_LOCAL/}"
    dest="$WT_PATH/$rel"
    dest_dir="$(dirname "$dest")"

    # Only copy if the target file exists or we are in a same-kind-repo scenario
    # (applicability already verified above — target file either existed or differed)
    # We copy regardless of whether target file exists (new file to a repo that shares the pattern)
    mkdir -p "$dest_dir" 2>/dev/null || true
    if cp "$sf" "$dest" 2>/dev/null; then
      COPIED_FILES="${COPIED_FILES} $rel"
      echo "  copied: $rel"
    else
      echo "  ERROR: failed to copy $rel -> $dest"
      COPY_FAILED=1
    fi
  done <<EOF
$SOURCE_FILES
EOF

  if [ "$COPY_FAILED" = "1" ]; then
    echo "  ERROR: copy failed — cleaning up worktree and skipping"
    git -C "$TARGET_LOCAL" worktree remove "$WT_PATH" --force 2>/dev/null || true
    FAILED_REPOS="${FAILED_REPOS}${target_slug}(copy-failed) "
    continue
  fi

  # Stage only the files we copied (never `git add .`)
  for rel_file in $COPIED_FILES; do
    git -C "$WT_PATH" add "$rel_file" 2>&1 | sed 's/^/  /'
  done

  # Commit
  # Lowercase subject for commitlint; blank line before Co-Authored-By
  COMMIT_MSG="chore: propagate ${PATH_GLOB} from ${SOURCE_SLUG}

Automated propagation by Whisky AI OS propagate.sh.
Source: ${SOURCE_SLUG}/${PATH_GLOB} — branch: ${PROP_BRANCH}

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"

  if git -C "$WT_PATH" commit -m "$COMMIT_MSG" 2>&1 | sed 's/^/  /'; then
    echo "  committed"
  else
    echo "  ERROR: commit failed — skipping push+PR for $target_slug"
    git -C "$TARGET_LOCAL" worktree remove "$WT_PATH" --force 2>/dev/null || true
    FAILED_REPOS="${FAILED_REPOS}${target_slug}(commit-failed) "
    continue
  fi

  # Push branch (NEVER force-push)
  if git -C "$WT_PATH" push origin "$PROP_BRANCH" 2>&1 | sed 's/^/  /'; then
    echo "  pushed branch: $PROP_BRANCH"
  else
    echo "  ERROR: push failed for $target_slug"
    git -C "$TARGET_LOCAL" worktree remove "$WT_PATH" --force 2>/dev/null || true
    FAILED_REPOS="${FAILED_REPOS}${target_slug}(push-failed) "
    continue
  fi

  # Open PR via gh (NEVER merge)
  PR_BODY="## Propagation via Whisky AI OS

This PR propagates a cross-cutting improvement from \`${SOURCE_SLUG}\`:

- **Source file(s):** \`${PATH_GLOB}\`
- **Source repo:** \`$OS_ORG/${SOURCE_SLUG}\`
- **Propagation date:** ${DATESTAMP}
- **Branch:** \`${PROP_BRANCH}\`

### What changed
$(python3 -c "
import subprocess,sys
files='$COPIED_FILES'.split()
out=[]
src='$SOURCE_LOCAL'
tgt='$WT_PATH'
for f in files:
    try:
        r=subprocess.run(['diff','-u',tgt+'/'+f,src+'/'+f],capture_output=True,text=True)
        lines=r.stdout.split('\n')
        add=sum(1 for l in lines if l.startswith('+') and not l.startswith('+++'))
        rem=sum(1 for l in lines if l.startswith('-') and not l.startswith('---'))
        out.append('- \`%s\`: +%d/-%d lines'%(f,add,rem))
    except Exception as e:
        out.append('- \`%s\`: (diff unavailable)'%f)
print('\n'.join(out))
" 2>/dev/null || echo "- see diff")

### Review checklist
- [ ] Diff looks correct for this repo's context
- [ ] CI passes
- [ ] Merge when ready (Whisky OS does NOT auto-merge)

🤖 Opened by [Whisky AI OS propagate.sh](https://github.com/$OS_REPO_SLUG/blob/main/ops/propagate.sh)"

  PR_URL="$(gh pr create \
    --repo "${GH_USER}/${target_slug}" \
    --head "$PROP_BRANCH" \
    --base main \
    --title "$PR_TITLE" \
    --body "$PR_BODY" 2>&1)" || true

  if echo "$PR_URL" | grep -q "https://github.com"; then
    echo "  PR opened: $PR_URL"
    OPENED_PRS="${OPENED_PRS}${target_slug}: ${PR_URL}\n"
  else
    echo "  WARN: gh pr create output unexpected: $PR_URL"
    # Might already exist or other non-fatal issue
    OPENED_PRS="${OPENED_PRS}${target_slug}: (check gh output above)\n"
  fi

  # Worktree can stay alive (human reviews PR); cleanup.sh prunes after merge
  echo "  done: $target_slug"
  echo ""
done

# ---------------------------------------------------------------------------
# Summary + notify
# ---------------------------------------------------------------------------
echo ""
echo "=== Propagation complete ==="
if [ -n "$OPENED_PRS" ]; then
  echo "Opened PRs:"
  printf "%b" "$OPENED_PRS" | sed 's/^/  /'
fi
if [ -n "$FAILED_REPOS" ]; then
  echo "Failed repos (manual intervention needed):"
  echo "  $FAILED_REPOS"
fi

# Notify via notify.sh (apply mode only, so worth alerting)
NOTIFY_MSG="Propagation run: ${PATH_GLOB} from ${SOURCE_SLUG}"
PR_LIST="$(printf "%b" "$OPENED_PRS" | python3 -c "
import sys
lines=[l for l in sys.stdin.read().split('\n') if l.strip()]
print('\n'.join(lines[:8]))
" 2>/dev/null)"

if [ -x ./notify.sh ]; then
  ./notify.sh "Propagate" "$NOTIFY_MSG" "${PR_LIST:-no PRs}" >/dev/null 2>&1 \
    || echo "propagate: notify.sh call failed (check Telegram creds)" >&2
else
  echo "propagate: notify.sh not found — skipping Telegram alert" >&2
fi

exit 0
