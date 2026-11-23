#!/usr/bin/env bash
#
# worktree-report.sh — Tier 4 #12. REPORTS on idle worktrees. Never deletes.
#
# Ahmad had to notice 52 GB of stale worktrees himself. `worktree-cleanup.sh`
# exists but nothing ever prompts it. This is the prompt.
#
# It NEVER deletes, and that is deliberate, not timidity:
#   * A worktree can hold uncommitted work that exists nowhere else.
#   * Parallel sessions run in worktrees RIGHT NOW. On 2026-08-11 three
#     client-repo and two ERP worktrees were 0 days old and belonged to
#     other live sessions — auto-deleting on an age heuristic would have
#     destroyed active work from a session this one cannot see.
# So: classify, print the exact command, let a human run it.
#
# Classification:
#   ACTIVE   <2d old, or dirty          -> never suggest
#   MERGED   branch merged to main/master, clean -> safe to remove
#   STALE    old + clean + unmerged     -> review; branch may still matter
#   ORPHAN   git no longer tracks it    -> `git worktree prune` territory

# shellcheck source=lib/os-config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/os-config.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-config.sh" 2>/dev/null || true
command -v os_config_load >/dev/null 2>&1 && os_config_load
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/wt-roots.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/wt-roots.sh" 2>/dev/null || true
[ -n "${WT_ROOT:-}" ] && WT_ROOT_SET=1
WT_ROOT="${WT_ROOT:-$OS_PROJECTS_DIR/_worktrees}"
STATE_DIR="${WHISKY_STATE_DIR:-$HOME/.whisky-os-state}"
IDLE_DAYS="${IDLE_DAYS:-7}"
mkdir -p "$STATE_DIR"

# Roots: an explicit WT_ROOT wins; else every existing root (internal + SSD). A missing root is skipped.
if [ -n "${WT_ROOT_SET:-}" ] || ! command -v wt_all_roots >/dev/null 2>&1; then WT_ROOTS="$WT_ROOT"; else WT_ROOTS="$(wt_all_roots)"; fi
[ -d "$WT_ROOT" ] || [ -n "$WT_ROOTS" ] || { echo "no worktree root at $WT_ROOT"; exit 0; }
wt_dirs() { local _r; while IFS= read -r _r; do [ -d "$_r" ] && printf '%s\n' "$_r"/*/; done <<EOR
$WT_ROOTS
EOR
}

active=0; merged=0; stale=0; total_kb=0
merged_list=(); stale_list=()

for d in $(wt_dirs); do
  [ -d "$d" ] || continue
  name=$(basename "$d")
  age=$(( ( $(date +%s) - $(stat -c %Y "$d" 2>/dev/null || stat -f %m "$d" 2>/dev/null || echo 0) ) / 86400 ))
  kb=$(du -sk "$d" 2>/dev/null | cut -f1); total_kb=$((total_kb + kb))
  sz=$(du -sh "$d" 2>/dev/null | cut -f1)
  br=$(git -C "$d" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")
  dirty=$(git -C "$d" status --porcelain 2>/dev/null | wc -l | tr -d ' ')

  if [ "$age" -lt 2 ] || [ "${dirty:-0}" -gt 0 ]; then
    active=$((active+1)); continue
  fi

  # Merged? `merge-base --is-ancestor` alone is WRONG here: a SQUASH-merged
  # branch's commits never become ancestors of main, so all six merged worktrees
  # on 2026-08-11 were misclassified as "unmerged, work may be unlanded" — the
  # documented squash-merge trap. Ask GitHub for the PR state as well.
  is_merged=no
  for base in origin/main origin/master; do
    if git -C "$d" merge-base --is-ancestor HEAD "$base" 2>/dev/null; then is_merged=yes; break; fi
  done
  if [ "$is_merged" = no ]; then
    repo=$(git -C "$d" remote get-url origin 2>/dev/null | sed 's|.*github.com[:/]||;s|\.git$||')
    if [ -n "$repo" ]; then
      pr_state=$(gh pr list --repo "$repo" --head "$br" --state all --json state --jq '.[0].state' 2>/dev/null)
      [ "$pr_state" = "MERGED" ] && is_merged=yes
    fi
  fi

  if [ "$is_merged" = yes ]; then
    merged=$((merged+1)); merged_list+=("$name|$sz|$age|$br")
  elif [ "$age" -ge "$IDLE_DAYS" ]; then
    stale=$((stale+1)); stale_list+=("$name|$sz|$age|$br")
  fi
done

total_gb=$(python3 -c "print(f'{$total_kb/1024/1024:.1f}')")

echo "Worktrees: $(wt_dirs | grep -c . || true) using ${total_gb}GB"
echo "  active (recent or dirty — NOT touched): $active"
echo "  merged + clean (safe to remove):        $merged"
echo "  stale >${IDLE_DAYS}d, clean, unmerged (review):  $stale"

if [ "${#merged_list[@]}" -gt 0 ]; then
  echo
  echo "SAFE TO REMOVE — branch already merged, nothing uncommitted:"
  for row in ${merged_list[@]+"${merged_list[@]}"}; do
    IFS='|' read -r n s a b <<< "$row"
    printf "  %-46s %7s  %sd  %s\n" "$n" "$s" "$a" "$b"
  done
fi

if [ "${#stale_list[@]}" -gt 0 ]; then
  echo
  echo "REVIEW — idle but the branch is NOT merged (work may be unlanded):"
  for row in ${stale_list[@]+"${stale_list[@]}"}; do
    IFS='|' read -r n s a b <<< "$row"
    printf "  %-46s %7s  %sd  %s\n" "$n" "$s" "$a" "$b"
  done
fi

echo
echo "Remove one with:  git -C <its repo> worktree remove <path>"
echo "Or the helper:    ~/.claude/scripts/worktree-cleanup.sh"

# Ops tile
ok="true"; [ "$merged" -gt 0 ] && ok="warn"
python3 - "$STATE_DIR/worktree-status.json" "$total_gb" "$active" "$merged" "$stale" "$ok" <<'PY'
import json, sys, datetime
dst, gb, active, merged, stale, ok = sys.argv[1:7]
json.dump({"ok": ok,
           "summary": f"{gb}GB across worktrees · {merged} merged+clean reclaimable · {active} active",
           "detail": {"total_gb": float(gb), "active": int(active),
                      "merged_clean": int(merged), "stale_unmerged": int(stale),
                      "note": "reports only; never deletes (parallel sessions live here)"},
           "checked_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")},
          open(dst, "w"), indent=1)
PY
