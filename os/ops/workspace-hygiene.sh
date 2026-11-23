#!/usr/bin/env bash
# Whisky AI OS — workspace-hygiene.sh (hourly launchd ${OS_LAUNCHD_PREFIX}.workspace-hygiene)
#
# Keeps the working forest clean WITHOUT ever destroying work (2026-07-11, on
# Ahmad's ask: "prevent dirty worktrees and things left behind I don't know about").
#
#   1. worktree-cleanup.sh          (dead refs, merged branches, park roots on main)
#   2. REMOVE worktree dirs whose branch is merged to origin/main AND tree is clean
#      — this is where the real storage goes (each carries a full node_modules)
#   3. REMOVE orphan worktree dirs (<repo>__<slug>, any depth, NOT inside a repo: lib/wt-safety.sh wt_candidates) that git
#      no longer registers (no .git link);
#      the business/client CONTAINER dirs they live in are never removed
#   4. REPORT (never touch): dirty/uncommitted worktrees with age+size, stashes
#      across repos, _worktrees/_backups disk totals
#   5. Telegram digest when anything was cleaned or needs a human decision
#
# SAFETY: only `git worktree remove` on CLEAN+MERGED trees; dirty/unmerged/unpushed
# are reported, never deleted. DRY_RUN=1 to preview.
#
# TWO MODES (2026-10-22 — cleanup used to depend on the agent remembering, plus one daily sweep):
#   (no args)              the full hourly sweep above — the BACKSTOP for merges done in the GitHub UI,
#                          auto-merge, and the worktree a session was standing in when it merged.
#   --repo <owner/repo>    FAST, repo-scoped mode, fired by hooks/post-merge-auto-cleanup.sh right after
#                          `gh pr merge`. Only worktrees whose origin slug matches; ONE fetch of that repo
#                          (so the ancestor check is fresh); skips step 1 (it fetches EVERY repo), orphan
#                          removal (an orphan cannot be attributed to a repo), the stash scan, the status
#                          file and Telegram. Same clean+merged safety gates.
#   --skip <path>          never remove the worktree at/containing <path> (the calling session's cwd —
#                          removing it would break that session). Reported as "kept (active session)";
#                          the hourly sweep removes it once the session has left.
# shellcheck source=lib/os-config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/os-config.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-config.sh" 2>/dev/null || true
command -v os_config_load >/dev/null 2>&1 && os_config_load
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
[ -n "${OS_SHIM_DIR:-}" ] && PATH="$OS_SHIM_DIR:$PATH"   # test seam: fake du/df/rm shims
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# S0 (2026-10-26): --help and unknown flags are handled BEFORE anything acts; one sweep at a time.
. "$HERE/lib/args.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/args.sh" || exit 2
args_help "${BASH_SOURCE[0]}" "$@"
. "$HERE/lib/single-instance.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/single-instance.sh" || exit 2
. "$HERE/lib/os-state.sh" 2>/dev/null || true
. "$HERE/lib/wt-safety.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/wt-safety.sh" 2>/dev/null || { echo "workspace-hygiene: lib/wt-safety.sh missing; refusing to reap without the safety checks" >&2; exit 2; }

# TCC canary (2026-07-12): abort when the launchd context cannot see ~/Desktop
OS_JOB_NAME=workspace-hygiene
if command -v require_projects_access >/dev/null 2>&1; then require_projects_access || exit 0; fi


ORIG_ARGS=("$@")   # the parse loop below shifts $@ away; the locked outer run re-execs the inner sweep with these
DRY="${DRY_RUN:-0}"
# a du that hangs must not hang the sweep: bounded, "?" on timeout/failure (UNKNOWN is a state, never 0)
_du_h() { local o; o="$(_ut "${HYGIENE_DU_TIMEOUT:-30}" du -sh "$1" 2>/dev/null | cut -f1)"; printf '%s' "${o:-?}"; }
_df_avail_kb() { _ut "${HYGIENE_DF_TIMEOUT:-20}" df -k "$HOME" 2>/dev/null | awk 'NR==2{print $4}' | tr -dc '0-9'; }
# df is the sweep's precondition: unreadable disk state = UNKNOWN = a dry run that deletes nothing
if [ "${HYGIENE_INNER:-0}" = 1 ] && ! _ut "${HYGIENE_DF_TIMEOUT:-20}" df -k "$HOME" >/dev/null 2>&1; then
  DRY=1; echo "workspace-hygiene: UNKNOWN - df did not answer; this run is a DRY RUN (nothing is deleted)"
fi
REPO_FILTER=""; SKIP_PATH=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO_FILTER="$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]')"; shift 2 || shift ;;
    --skip) SKIP_PATH="${2:-}"; shift 2 || shift ;;
    *) args_unknown "${BASH_SOURCE[0]}" "$1" ;;
  esac
done
# One sweep at a time. A repo-scoped run that finds the sweep busy QUEUES its slug (the running sweep drains the queue
# when it finishes; the hourly sweep is the backstop for the last-instant race) instead of starting a parallel one.
Q="${HYGIENE_QUEUE:-$HOME/.whisky-os-state/hygiene.queue}"
if [ "${HYGIENE_INNER:-0}" != 1 ]; then
  mkdir -p "$(dirname "$Q")" 2>/dev/null
  if ! holder="$(si_acquire workspace-hygiene 2>&1)"; then
    if [ -n "$REPO_FILTER" ]; then
      printf '%s\t%s\n' "$REPO_FILTER" "$SKIP_PATH" >> "$Q"; echo "workspace-hygiene: sweep running (pid ${holder:-?}); queued $REPO_FILTER"
    else echo "workspace-hygiene: already running (pid ${holder:-?}), exiting"; fi
    exit 0
  fi
  trap 'si_release workspace-hygiene' EXIT
  HYGIENE_INNER=1 bash "${BASH_SOURCE[0]}" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}; rc=$?
  n=0
  while [ -s "$Q" ] && [ "$n" -lt 5 ]; do
    n=$((n + 1)); mv "$Q" "$Q.work.$$" 2>/dev/null || break
    sort -u "$Q.work.$$" | while IFS="$(printf '\t')" read -r qslug qskip; do
      [ -n "$qslug" ] && HYGIENE_INNER=1 bash "${BASH_SOURCE[0]}" --repo "$qslug" ${qskip:+--skip "$qskip"}
    done
    rm -f "$Q.work.$$"
  done
  exit "$rc"
fi
SKIP_P=""
[ -n "$SKIP_PATH" ] && [ -d "$SKIP_PATH" ] && SKIP_P="$(cd "$SKIP_PATH" && pwd -P)"
fetched=0
# every process's working dir (shells, Claude sessions, dev servers); a tree in use is never removed
live_cwds="${HYGIENE_LIVE_CWDS-$(lsof -a -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')}"
WT_ROOT="$OS_PROJECTS_DIR/_worktrees"   # internal root (kept for messages); the sweep walks EVERY existing root below
. "$(dirname "${BASH_SOURCE[0]}")/lib/wt-roots.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/wt-roots.sh" 2>/dev/null || true
PROJECTS="$OS_PROJECTS_DIR"
PROJECTS_ROOT="$PROJECTS"
stripped=()
# node_modules is gitignored + reproducible (wt-deps.sh); drop it from MERGED trees we keep for uncommitted junk
strip_deps() {
  local wt="$1" nm sz
  nm=$(cd "$wt" && find . -maxdepth 5 -type d -name node_modules -not -path '*/node_modules/*' -not -path './.git/*' -prune -print 2>/dev/null)
  [ -n "$nm" ] || return 0
  sz=$(cd "$wt" && printf '%s\n' "$nm" | _ut 60 xargs du -sck 2>/dev/null | tail -1 | cut -f1)
  [ "$DRY" = "1" ] || (cd "$wt" && printf '%s\n' "$nm" | while IFS= read -r d; do rm -rf "$d"; done)
  stripped+=("$name (~$(( ${sz:-0} / 1024 )) MB node_modules)")
}
removed=(); dirty=(); orphans=(); stashes=(); kept=()

# --- 1. the existing branch/ref cleanup ---
[ -z "$REPO_FILTER" ] && [ -x "$HERE/worktree-cleanup.sh" ] && bash "$HERE/worktree-cleanup.sh" 2>/dev/null | sed 's/^/  /'

# --- 2+3. sweep the _worktrees forest ---
# Worktrees are named <repo>__<slug> (new-task-worktree.sh) and, since the 2026-09-25 business-folder
# layout, sit NESTED: _worktrees/Whisky-11/clients/acme-client/acme-client-app__feat-x. The old one-level
# `"$WT_ROOT"/*/` loop saw the CONTAINER _worktrees/Whisky-11 (no .git of its own), called it an orphan and
# rm -rf'd it — with every live worktree inside, unpushed commits and all (2026-09-27 and 2026-09-28).
# Now: only a dir named *__* is a worktree candidate (found at any depth, not descended into); a container
# is never a candidate, so it is never removed.
# Two roots since 2026-11-19: internal $OS_PROJECTS_DIR/_worktrees AND the SSD (lib/wt-roots.sh wt_all_roots); a missing
# root (SSD unmounted) is simply absent from the list, so it is skipped, never an error.
while IFS= read -r WT_ROOT; do
  [ -d "$WT_ROOT" ] || continue
  while IFS= read -r wt; do
    [ -d "$wt" ] || continue
    name="${wt#"$WT_ROOT"/}"
    if [ ! -e "$wt/.git" ]; then
      [ -n "$REPO_FILTER" ] && continue   # repo mode: an orphan cannot be attributed to a repo
      # not a registered worktree anymore — leftover dir from a crashed removal
      sz=$(_du_h "$wt")
      orphans+=("$name ($sz)")
      [ "$DRY" = "1" ] || rm -rf "$wt"
      continue
    fi
    if [ -n "$REPO_FILTER" ]; then
      wt_slug=$(git -C "$wt" remote get-url origin 2>/dev/null | sed -E 's#.*github.com[:/]##; s#\.git$##' | tr '[:upper:]' '[:lower:]')
      [ "$wt_slug" = "$REPO_FILTER" ] || continue
      if [ "$fetched" = "0" ]; then
        fetched=1   # one fetch for the whole repo — worktrees share the object store
        _ut 60 git -C "$wt" fetch origin --quiet >/dev/null 2>&1 || true
      fi
    fi
    branch=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")
    dirty_files=$(wt_dirty_count "$wt")
    # merged ONLY when GitHub says a PR was merged at exactly this tip (lib/wt-safety.sh). A branch with no commit
    # beyond main is NEW (just created), never "merged"; offline/unknown keeps the tree.
    merged=0
    slug=$(git -C "$wt" remote get-url origin 2>/dev/null | sed -E 's#.*github.com[:/]##; s#\.git$##')
    verdict=$(wt_merge_verdict "$wt" "$slug" "$branch")
    [ "$verdict" = "merged" ] && merged=1
    # unpushed commits on an unmerged branch = work in flight — never touch
    if [ "$dirty_files" = "0" ] && [ "$merged" = "1" ]; then
      sz=$(_du_h "$wt")
      wt_p="$(cd "$wt" && pwd -P)"
      if [ -n "$SKIP_P" ] && case "$SKIP_P/" in "$wt_p/"*) true ;; *) false ;; esac; then
        kept+=("$name ($sz) [$branch]")
      elif printf '%s\n' "$live_cwds" | awk -v p="$wt_p" '$0==p || index($0, p"/")==1 {f=1} END{exit !f}'; then
        # hourly now, so another live session (or shell) may be standing in a merged tree — never pull it out from under them
        kept+=("$name ($sz) [$branch, in use]")
      elif [ "$DRY" = "1" ]; then
        removed+=("(dry) $name ($sz)")
      else
        # remove via the MAIN repo so git unregisters it properly
        main_repo=$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null | sed 's|/\.git.*||')
        # NO --force: git refuses to remove a tree holding modified/untracked files, atomically at removal time
        if git -C "${main_repo:-$wt}" worktree remove "$wt" 2>/dev/null; then
          removed+=("$name ($sz)")
        fi
      fi
    elif [ "$dirty_files" != "0" ]; then
      age_days=$(( ( $(date +%s) - $(stat -c %Y "$wt" 2>/dev/null || stat -f %m "$wt" 2>/dev/null || echo 0) ) / 86400 ))
      sz=$(_du_h "$wt")
      if [ "$merged" = "1" ]; then
        wt_p="$(cd "$wt" && pwd -P)"
        if printf '%s\n' "$live_cwds" | awk -v p="$wt_p" '$0==p || index($0, p"/")==1 {f=1} END{exit !f}'; then :
        elif [ -n "$SKIP_P" ] && case "$SKIP_P/" in "$wt_p/"*) true ;; *) false ;; esac; then :
        else strip_deps "$wt"; fi
      fi
      dirty+=("$name [$branch] — $dirty_files uncommitted file(s), ~${age_days}d, $sz")
    fi
  done < <(wt_candidates "$WT_ROOT")
done < <(command -v wt_all_roots >/dev/null 2>&1 && wt_all_roots || { [ -d "$WT_ROOT" ] && echo "$WT_ROOT"; })

# --- 4. stashes across root repos (invisible parked work) ---
if [ -z "$REPO_FILTER" ]; then
while IFS= read -r repo_dir; do
  n=$(git -C "$repo_dir" stash list 2>/dev/null | wc -l | tr -d ' ')
  [ "${n:-0}" -gt 0 ] && stashes+=("$(basename "$repo_dir"): $n stash(es)")
done < <(list_repo_roots)
fi

wt_size=""
while IFS= read -r _r; do wt_size="${wt_size:+$wt_size + }$(_du_h "$_r")"; done < <(command -v wt_all_roots >/dev/null 2>&1 && wt_all_roots || echo "$WT_ROOT")
bk_size=$(_du_h "$PROJECTS/_backups")

# --- 5. digest ---
echo "== workspace-hygiene =="
echo "removed merged+clean worktrees: ${#removed[@]}"
for r in "${removed[@]+"${removed[@]}"}"; do echo "  - $r"; done
if [ "${#kept[@]}" -gt 0 ]; then
  echo "kept (active session): ${#kept[@]}"
  for k in ${kept[@]+"${kept[@]}"}; do echo "  - $k"; done
fi
echo "node_modules dropped from merged-but-dirty trees: ${#stripped[@]}"
for t in "${stripped[@]+"${stripped[@]}"}"; do echo "  - $t"; done
echo "orphan dirs removed: ${#orphans[@]}"
for o in "${orphans[@]+"${orphans[@]}"}"; do echo "  - $o"; done
echo "DIRTY worktrees (left alone — commit, PR, or discard):"
if [ "${#dirty[@]}" -gt 0 ]; then for d in ${dirty[@]+"${dirty[@]}"}; do echo "  ! $d"; done; else echo "  none"; fi
echo "stashes: ${stashes[*]:-none}"
echo "_worktrees: ${wt_size:-0} · _backups: ${bk_size:-0}"

# --- disk alert: host free < WT_MIN_FREE_GB (30) -> Telegram via notify.sh (the OS's one channel), 6h cooldown ---
free_kb=$(_df_avail_kb); free_gb="${HYGIENE_FREE_GB_AFTER:-$([ -n "$free_kb" ] && echo $(( free_kb / 1024 / 1024 )) || echo '?')}"
echo "host free: ${free_gb} GB"
[ "$free_gb" = "?" ] && echo "host free: UNKNOWN (df unreadable) - no disk decision taken from it"
if [ -z "$REPO_FILTER" ] && [ "$free_gb" != "?" ] && [ "$free_gb" -lt "${WT_MIN_FREE_GB:-30}" ]; then
  stamp="$HOME/.cache/wt-deps/.disk-alert"; mkdir -p "$(dirname "$stamp")"
  last=$(stat -c %Y "$stamp" 2>/dev/null || stat -f %m "$stamp" 2>/dev/null || echo 0)
  if [ $(( $(date +%s) - last )) -gt 21600 ] && [ -x "$HERE/notify.sh" ]; then
    "$HERE/notify.sh" "💾 host disk LOW" "Mac has only ${free_gb} GB free (< ${WT_MIN_FREE_GB:-30}). A full disk fails CI runner jobs and degrades the Mac. New worktrees are blocked. _worktrees=${wt_size:-?}. Run workspace-hygiene.sh / remove merged trees." >/dev/null 2>&1 && touch "$stamp"
  fi
fi

if [ -z "$REPO_FILTER" ] && command -v write_status >/dev/null 2>&1; then
  ok=$({ [ "${#dirty[@]}" -gt 3 ] || [ "$free_gb" -lt "${WT_MIN_FREE_GB:-30}" ]; } && echo "warn" || echo "true")
  write_status "workspace-hygiene" "$ok" \
    "removed ${#removed[@]} merged worktree(s), ${#orphans[@]} orphan(s); ${#dirty[@]} dirty left; _worktrees=${wt_size:-?}" \
    "{\"removed\":${#removed[@]},\"dirty\":${#dirty[@]},\"orphans\":${#orphans[@]}}"
fi
# notify only when there is something a human should decide (dirty pileup) or real cleanup happened
if [ -z "$REPO_FILTER" ] && [ -x "$HERE/notify.sh" ] && { [ "${#removed[@]}" -gt 0 ] || [ "${#dirty[@]}" -gt 2 ]; }; then
  body="removed: ${#removed[@]} worktree(s), ${#orphans[@]} orphan dir(s). _worktrees now ${wt_size:-?}."
  if [ "${#dirty[@]}" -gt 0 ]; then
    body="$body
DIRTY (need commit/PR/discard):
$(printf '%s\n' ${dirty[@]+"${dirty[@]}"})"
  fi
  "$HERE/notify.sh" "🧹 workspace-hygiene" "$body" >/dev/null 2>&1 || true
fi
exit 0
