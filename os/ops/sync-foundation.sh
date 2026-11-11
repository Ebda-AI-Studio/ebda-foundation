#!/usr/bin/env bash
# sync-foundation.sh — keep the OS repo (ebda-foundation) drift-free.
#
# WHY: the foundation repo IS the Whisky AI OS, but it is DECOUPLED from the
# memory pipeline — update-memory-pipeline.sh only touches the vault + Claude
# memory + graphify, never this repo. So the OS's own MECHANICAL artifacts
# (the self-map ARCHITECTURE.md, the graphify-out graph) silently drift and
# merged PRs sit un-pulled on the root. This script is the mechanical bridge:
# the memory pipeline calls it every run so "memory updated" also means
# "foundation in sync, zero diff."
#
# WHAT IT SYNCS (mechanical, auto-committable — like the pipeline committing
# graphify to the vault):
#   1. Fast-forward master to origin (pull merged PRs).
#   2. Regenerate the self-map  -> ops/self-check.sh writes ARCHITECTURE.md.
#   3. Refresh the graph        -> graphify update . (AST-only, zero token cost).
#   4. Commit the allowlist (ARCHITECTURE.md) ON A BRANCH and open a PR —
#      master is protected, so a direct push is rejected. The root is left at
#      origin/master, clean.
#
# NOT synced any more (2026-08-24): graphify-out/. It stays TRACKED (the
# .gitignore deliberately un-ignores the 3 canonical artifacts, matching
# studio/store) but is no longer auto-committed — `graphify update .` rewrites it
# every run, and 99.3% of the resulting ~1,700-line diff was community-id
# renumbering across unchanged nodes.
#
# WHAT IT WILL NOT DO (needs reasoning -> stays a human PR):
#   - Author/standard/ops CONTENT changes. Any uncommitted change OUTSIDE the
#     allowlist is REPORTED as "content drift -> open a PR", never auto-committed.
#   - It never force-pushes, never merges, never touches another repo.
#
# Usage:
#   ops/sync-foundation.sh            # sync (commit+push allowlist)
#   ops/sync-foundation.sh --check    # report drift only, change nothing (exit 3 if drift)
#   ops/sync-foundation.sh --no-push  # commit locally, don't push
#
# Exit codes:
#   0 — in sync (or synced successfully)
#   1 — fatal (not a repo / missing tools)
#   3 — (--check) drift detected, nothing changed
# shellcheck source=lib/os-config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/os-config.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-config.sh" 2>/dev/null || true
command -v os_config_load >/dev/null 2>&1 && os_config_load
set -uo pipefail
. "$(dirname "$0")/lib/os-state.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-state.sh" 2>/dev/null || true

# TCC canary (2026-07-12): abort when the launchd context cannot see ~/Desktop
OS_JOB_NAME=sync-foundation
if command -v require_projects_access >/dev/null 2>&1; then require_projects_access || exit 0; fi


REPO_DEFAULT="$OS_HOME"
REPO="${FOUNDATION_REPO:-$REPO_DEFAULT}"
# The only paths this script may auto-commit.
#
# graphify-out/ was REMOVED from this list on 2026-08-24. It stays TRACKED in the
# repo (.gitignore deliberately un-ignores the 3 canonical artifacts, matching
# studio/store) — it is just no longer auto-committed, because regenerating it on every
# pipeline run produced ~1,700 insertions per sync of which 99.3% were community-id
# renumbering ("community": 22 -> 23) across unchanged nodes. A 4 MB blob whose
# diffs carry no information. It is refreshed by whatever PR actually changes the
# code it describes.
# the OS lives under os/ in the repo: the self-map is os/ARCHITECTURE.md, written by os/ops/self-check.sh (run from os/ops)
ALLOWLIST="os/ARCHITECTURE.md"
CHECK_ONLY=0; NO_PUSH=0
for a in "$@"; do
  case "$a" in
    --check)   CHECK_ONLY=1 ;;
    --no-push) NO_PUSH=1 ;;
  esac
done

ok()   { printf '\033[32m%s\033[0m\n' "$*"; }
warn() { printf '\033[33m%s\033[0m\n' "$*"; }
err()  { printf '\033[31m%s\033[0m\n' "$*" >&2; }
info() { printf '%s\n' "$*"; }

command -v git >/dev/null 2>&1 || { err "git not found"; exit 1; }
[ -d "$REPO/.git" ] || { err "not a repo: $REPO"; exit 1; }
cd "$REPO" || exit 1

br="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
info "── sync-foundation: $REPO ($br) ──"

# Refuse to operate on a feature branch — this only maintains master.
case "$br" in
  master|main) ;;
  *) warn "   on '$br' (not master) — skipping foundation sync to avoid touching feature work."; exit 0 ;;
esac

# is_outside_allowlist <porcelain-path>: 0 if the path is NOT covered by the allowlist
is_outside_allowlist() {
  local p="$1" a
  for a in $ALLOWLIST; do
    case "$p" in "$a"|"$a"/*) return 1 ;; esac
  done
  # graphify-out/ differs on EVERY run: `graphify update .` rewrites it locally each
  # tick. It stays tracked (canonical artifacts, matching studio/store) but is no longer
  # auto-committed, so it is neither allowlisted nor drift — it is noise. Reporting
  # it as CONTENT DRIFT every run would train everyone to ignore the drift warning,
  # which is the one that catches real un-PR'd edits.
  case "$p" in graphify-out|graphify-out/*) return 1 ;; esac
  return 0
}

# Snapshot pre-existing CONTENT drift (uncommitted changes outside the allowlist)
# BEFORE we regenerate anything, so we can report (and never auto-commit) it.
content_drift=""
while IFS= read -r line; do
  [ -n "$line" ] || continue
  path="${line:3}"
  if is_outside_allowlist "$path"; then
    content_drift="${content_drift}${line}"$'\n'
  fi
done < <(git status --porcelain)

# ── 1. fast-forward master to origin ────────────────────────────────────────
git fetch origin --quiet 2>/dev/null || warn "   fetch failed (offline?) — continuing with local state"
behind="$(git rev-list --count "HEAD..origin/$br" 2>/dev/null || echo 0)"

# Ahead is drift too, and it was invisible here. master is protected, so a local
# commit on it can never be pushed — it sits there and the root diverges further
# every run. ops/install.sh installs from the LOCAL WORKING TREE, so a diverged
# root ships code that is not on origin (2026-08-22: it shipped a stale runner
# guard, and `diff` called it identical because both copies were behind). Report
# loudly; never resolve automatically — discarding commits is not this script's call.
ahead="$(git rev-list --count "origin/$br..HEAD" 2>/dev/null || echo 0)"
if [ "$ahead" != "0" ]; then
  warn "   ⚠ local is $ahead commit(s) ahead of origin/$br — unpushable on a protected branch."
  warn "     ops/install.sh installs from this tree, so it can ship code NOT on origin."
  warn "     Resolve: PR them, or 'git reset --hard origin/$br' if they are regenerable artifacts."
  content_drift="${content_drift} (local is $ahead commit(s) ahead of origin/$br — unpushable)"$'\n'
fi
if [ "$behind" != "0" ]; then
  if [ "$CHECK_ONLY" = "1" ]; then
    warn "   behind origin/$br by $behind commit(s) (would fast-forward)"
  elif git merge --ff-only "origin/$br" --quiet 2>/dev/null; then
    ok "   ✓ fast-forwarded $behind commit(s) from origin/$br"
  else
    warn "   ⚠ cannot fast-forward (local commits or conflict) — leaving for human. Reporting as drift."
    content_drift="${content_drift} (local diverged from origin/$br by behind=$behind)"$'\n'
  fi
fi

# ── convergence gate: only regenerate when SOURCE actually changed ──────────
# The graph + self-map embed the build commit + file mtimes, so regenerating
# every run would churn a commit forever and never converge. Skip regeneration
# when HEAD is unchanged since the last sync AND no tracked source file is dirty.
STATE_DIR="$HOME/.whisky-os-state"; mkdir -p "$STATE_DIR" 2>/dev/null || true
MARKER="$STATE_DIR/foundation-last-sync-commit"
head_now="$(git rev-parse HEAD 2>/dev/null)"
last_sync="$(cat "$MARKER" 2>/dev/null || echo none)"
# source = every tracked path EXCEPT the generated graph + self-map
src_drift="$(git status --porcelain -- . ':(exclude)graphify-out' ':(exclude)os/ARCHITECTURE.md' 2>/dev/null | head -1)"
REGEN=1
# The marker alone is NOT evidence the graph is current: it records what this script
# BELIEVES it last synced, not what the graph actually contains. On 2026-09-04 the
# marker said 332a68ec while graph.json's own built_at_commit was 82e570c3 — 26
# commits earlier — and this check reported "current" every run. A freshness check
# that reads its own bookkeeping instead of the artifact is the same shape as an
# alert that measures the monitor. So: ask the graph what it was built from.
graph_commit="$(python3 -c "
import json,sys
try: print(json.load(open('graphify-out/graph.json')).get('built_at_commit') or '')
except Exception: print('')" 2>/dev/null)"
graph_stale=0
if [ -n "$graph_commit" ] && [ "$graph_commit" != "$head_now" ]; then
  graph_stale=1
fi

if [ "$head_now" = "$last_sync" ] && [ -z "$src_drift" ] && [ "$behind" = "0" ] && [ "$graph_stale" = "0" ]; then
  REGEN=0
  ok "   ✓ no source change since last sync (${head_now:0:8}) — graph + self-map current"
elif [ "$graph_stale" = "1" ] && [ "$head_now" = "$last_sync" ] && [ -z "$src_drift" ]; then
  warn "   ⚠ marker says current (${head_now:0:8}) but graph.json was built at ${graph_commit:0:8} — regenerating"
fi

# ── 2. regenerate the self-map (only when source changed) ───────────────────
if [ "$REGEN" = "1" ] && [ -x "os/ops/self-check.sh" ]; then
  ( cd os/ops && bash self-check.sh >/dev/null 2>&1 ) || true   # exits non-zero on ERROR findings; the map is still written
  ok "   ✓ regenerated self-map (os/ARCHITECTURE.md)"
fi

# ── 3. refresh the graph (AST-only, no token cost; only when source changed) ─
if [ "$REGEN" = "1" ] && command -v graphify >/dev/null 2>&1; then
  graphify update . >/dev/null 2>&1 || warn "   ⚠ graphify update failed — graph may be stale"
  ok "   ✓ refreshed graphify-out"
fi

# ── 4. detect, then (real run only) commit ONLY the allowlist ───────────────
# Detect WHAT WOULD be staged WITHOUT mutating the index — gitignore-aware, so
# graphify-out/cache/ is excluded. --check must never touch the index.
pending="$(git add --dry-run --ignore-errors -- $ALLOWLIST 2>/dev/null \
  | sed -E "s/^add '(.*)'$/\1/")"

# ARCHITECTURE.md carries a `_Last-commit date:` stamp that moves on every run even
# when the self-map is identical. Committing that alone means a commit (and, below,
# a PR) per pipeline tick that says nothing. If the ONLY change is that line, revert
# the file and treat it as no change.
if [ -n "$pending" ]; then
  real_change="$(git diff -U0 -- os/ARCHITECTURE.md \
    | grep -E '^[-+]' | grep -vE '^(\+\+\+|---)' \
    | grep -vE '^[-+]_Last-commit date:' || true)"
  if [ -z "$real_change" ]; then
    git checkout -- os/ARCHITECTURE.md 2>/dev/null || true
    pending=""
    ok "   ✓ self-map unchanged (date stamp only) — nothing to commit"
  fi
fi

# Report content drift regardless of mode.
if [ -n "$content_drift" ]; then
  warn "   ⚠ CONTENT DRIFT (outside allowlist — NOT auto-committed; open a PR):"
  printf '%s' "$content_drift" | sed 's/^/        /'
fi

if [ -z "$pending" ]; then
  ok "   ✓ self-map + graph already in sync — no artifact changes"
  # remember we are current at this commit so future ticks skip regeneration
  [ "$CHECK_ONLY" = "0" ] && printf '%s' "$head_now" > "$MARKER"
elif [ "$CHECK_ONLY" = "1" ]; then
  warn "   would commit allowlist artifacts:"; printf '%s\n' "$pending" | sed 's/^/        /'
else
  # master is a PROTECTED branch: PR required, enforce_admins=true, no force
  # push. A direct `git push origin master` is REJECTED ("protected branch hook
  # declined"), so the old code committed to the local root and failed to push —
  # forever. Those commits then accumulated (2 by 2026-08-23) and left the root
  # AHEAD of origin, which is what made ops/install.sh ship a STALE runner guard
  # while `diff` called it identical (both copies were behind).
  #
  # So: never commit on master here. Carry the change on a branch and open a PR,
  # leaving the root exactly at origin/master — clean, and safe to install from.
  if [ "$NO_PUSH" = "1" ]; then
    git add -- $ALLOWLIST 2>/dev/null || true
    git commit -q -m "chore(os): sync self-map [skip ci]" \
      -m "Mechanical foundation sync via ops/sync-foundation.sh. Allowlist: ARCHITECTURE.md." \
      && ok "   ✓ committed allowlist artifacts locally (--no-push)"
    printf '%s' "$(git rev-parse HEAD)" > "$MARKER"
  elif ! command -v gh >/dev/null 2>&1; then
    warn "   ⚠ gh not found — leaving the self-map change UNCOMMITTED rather than"
    warn "     stranding an unpushable commit on the root. Commit it in a PR."
  else
    sync_br="chore/os-selfmap-$(git log -1 --format=%cd --date=format:%Y%m%d%H%M origin/"$br" 2>/dev/null || echo manual)"
    # carry the regenerated allowlist files across the branch switch by copying them aside (never the shared stack)
    bak="$(mktemp -d)"
    for _f in $ALLOWLIST; do mkdir -p "$bak/$(dirname "$_f")"; cp -p "$_f" "$bak/$_f" 2>/dev/null || true; done
    git checkout -q -- $ALLOWLIST 2>/dev/null || true
    restore_allowlist() { for _f in $ALLOWLIST; do [ -f "$bak/$_f" ] && cp -p "$bak/$_f" "$_f"; done; return 0; }
    if git checkout -q -B "$sync_br" "origin/$br" 2>/dev/null; then
      restore_allowlist
      git add -- $ALLOWLIST 2>/dev/null || true
      if git commit -q -m "chore(os): sync self-map [skip ci]" \
           -m "Mechanical foundation sync via ops/sync-foundation.sh (called by the memory pipeline). Allowlist: ARCHITECTURE.md. Opened as a PR because master is protected."; then
        if git push -q -u origin "$sync_br" 2>/dev/null; then
          if gh pr create --base "$br" --head "$sync_br" \
               --title "chore(os): sync self-map" \
               --body "Mechanical self-map refresh from \`ops/sync-foundation.sh\`. Date-stamp-only changes are suppressed, so this PR means ARCHITECTURE.md actually changed." >/dev/null 2>&1; then
            ok "   ✓ opened PR for self-map drift ($sync_br)"
          else
            warn "   ⚠ pushed $sync_br but could not open a PR — open it manually"
          fi
        else
          warn "   ⚠ could not push $sync_br — self-map change left on that branch"
        fi
      fi
    else
      warn "   ⚠ could not create $sync_br — leaving working tree as-is"
      restore_allowlist
    fi
    rm -rf "$bak"
    # Always return the root to the protected branch, tracking origin, clean.
    git checkout -q "$br" 2>/dev/null || true
    printf '%s' "$(git rev-parse HEAD)" > "$MARKER"
  fi
fi

# ── exit ────────────────────────────────────────────────────────────────────
if [ "$CHECK_ONLY" = "1" ]; then
  if [ -n "$content_drift" ] || [ -n "$pending" ] || [ "$behind" != "0" ]; then
    warn "   DRIFT present (see above)."; exit 3
  fi
  ok "   ✓ foundation fully in sync — zero diff."; exit 0
fi
ok "   ✓ foundation sync complete."
exit 0
