#!/usr/bin/env bash
# Whisky AI OS — drift-watch.sh (weekly launchd ${OS_LAUNCHD_PREFIX}.drift-watch)
#
# Sources of truth drift silently — that's the failure class behind three
# 2026-07-11 finds: installed ~/.claude/scripts edits never synced to ops/,
# the foundation repo sitting 45 commits UNPUSHED (a new Mac would clone a
# stale OS), and launchd plists diverging from their templates. This job
# alerts on all three while the drift is one week old, not one month.
#
#   1. installed ~/.claude/scripts/*.sh|lib/* vs foundation ops/ (byte diff)
#   2. foundation repo: unpushed commits + uncommitted tracked changes
#   3. installed LaunchAgents vs ops/launchd templates (token-substituted)
# shellcheck source=lib/os-config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/os-config.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-config.sh" 2>/dev/null || true
command -v os_config_load >/dev/null 2>&1 && os_config_load
set -uo pipefail
# S0 (2026-10-26): --help runs nothing; one run at a time (lib/single-instance.sh)
. "$(dirname "${BASH_SOURCE[0]}")/lib/args.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/args.sh" || exit 2
. "$(dirname "${BASH_SOURCE[0]}")/lib/single-instance.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/single-instance.sh" || exit 2
args_help "${BASH_SOURCE[0]}" "$@"
single_instance drift-watch
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/os-state.sh" 2>/dev/null || true

# TCC canary (2026-07-12): abort when the launchd context cannot see ~/Desktop
OS_JOB_NAME=drift-watch
if command -v require_projects_access >/dev/null 2>&1; then require_projects_access || exit 0; fi


# Resolve the foundation checkout (source of truth) — this script may run from
# the INSTALLED copy in ~/.claude/scripts, so never assume $HERE is the repo.
# the OS lives under os/ in ebda-foundation (os/ops, os/launchd/mac-local.list); $OS_HOME/ops does not exist, so the old
# "$F/ops" made every run exit 0 at "ops dir missing" (a silently dead watcher, found 2026-11-10)
F="$OS_HOME"
OPS="$F/os/ops"; INST="$HOME/.claude/scripts"
MAC_LIST="$F/os/launchd/mac-local.list"
issues=()

if [ ! -d "$OPS" ]; then
  echo "drift-watch: foundation ops dir missing at $OPS"; exit 0
fi

# --- 1. installed scripts vs ops source ---
while IFS= read -r rel; do
  src="$OPS/$rel"; dst="$INST/$rel"
  [ -f "$dst" ] || { issues+=("NOT-INSTALLED: $rel (in ops/, missing from ~/.claude/scripts — run ops/install.sh)"); continue; }
  diff -q "$src" "$dst" >/dev/null 2>&1 || issues+=("DIVERGED: $rel (installed ≠ ops source — sync whichever is newer, then install.sh)")
done < <(cd "$OPS" && find . lib -maxdepth 1 \( -name '*.sh' -o -name '*.py' \) -type f 2>/dev/null | sed 's|^\./||' | sort -u)
# installed scripts that exist nowhere in ops (edits that would die on reinstall)
while IFS= read -r rel; do
  [ -f "$OPS/$rel" ] || issues+=("ORPHAN-INSTALL: $rel (only in ~/.claude/scripts — will not survive install.sh or reach a new Mac)")
done < <(cd "$INST" && find . lib -maxdepth 1 \( -name '*.sh' -o -name '*.py' \) -type f 2>/dev/null | sed 's|^\./||' | sort -u)

# --- 2. foundation repo push/commit state ---
git -C "$F" fetch -q origin 2>/dev/null || true
unpushed=$(git -C "$F" rev-list --count origin/main..main 2>/dev/null || echo 0)
[ "${unpushed:-0}" -gt 0 ] && issues+=("UNPUSHED: foundation main is $unpushed commit(s) ahead of origin — a new Mac clones a stale OS")
dirty=$(git -C "$F" status --porcelain --untracked-files=no 2>/dev/null | wc -l | tr -d ' ')
[ "${dirty:-0}" -gt 0 ] && issues+=("DIRTY: foundation has $dirty uncommitted tracked change(s)")

# --- 3. plists vs templates ---
BREW="$(command -v brew >/dev/null 2>&1 && brew --prefix 2>/dev/null || echo /opt/homebrew)"
# only the Mac-local set (os/launchd/mac-local.list, what os/install.sh installs) is expected on this Mac; the other templates are
# jobs the brain runs now and must NOT be reported missing
while IFS=$'\t' read -r _name _rel _flag; do
  case "$_name" in ''|'#'*) continue ;; esac
  # an opt-in job (3rd column `optin=VAR`, ruling INSTALL-1) is expected only when VAR=1
  case "${_flag:-}" in optin=*) _v="${_flag#optin=}"; [ "${!_v:-}" = 1 ] || continue ;; esac
  tmpl="$F/os/$_rel"
  [ -f "$tmpl" ] || { issues+=("TEMPLATE-MISSING: $_rel (listed in mac-local.list)"); continue; }
  label="${OS_LAUNCHD_PREFIX}.$_name"
  inst_plist="$HOME/Library/LaunchAgents/$label.plist"
  [ -f "$inst_plist" ] || { issues+=("PLIST-MISSING: $label not installed"); continue; }
  # compare with tokens substituted, but PATH varies by machine — strip PATH lines
  if ! diff -q <(sed -e "s#__HOME__#$HOME#g" "$tmpl" | grep -v "$BREW\|__PATH__") \
               <(grep -v "$BREW\|/usr/local/bin\|\.local/bin\|nvm" "$inst_plist" | grep -v '<string>/') >/dev/null 2>&1; then
    # loose structural compare only on schedule + program lines
    t_sig=$(grep -E 'Label|Program|Integer|integer' "$tmpl" | tr -d ' \t')
    i_sig=$(grep -E 'Label|Program|Integer|integer' "$inst_plist" | tr -d ' \t' | sed "s#$HOME#__HOME__#g")
    [ "$t_sig" = "$i_sig" ] || issues+=("PLIST-DRIFT: $label (schedule/program differs from template)")
  fi
done < <([ -f "$MAC_LIST" ] && cat "$MAC_LIST")

echo "== drift-watch =="
if [ "${#issues[@]}" -eq 0 ]; then
  echo "  clean — installed runtime, foundation repo, and plists all in sync."
  command -v write_status >/dev/null 2>&1 && write_status "drift-watch" "true" "no source-of-truth drift" '{}'
  exit 0
fi
for i in ${issues[@]+"${issues[@]}"}; do echo "  ! $i"; done
command -v write_status >/dev/null 2>&1 && write_status "drift-watch" "warn" "${#issues[@]} drift issue(s)" "{\"count\":${#issues[@]}}"
if [ -x "$HERE/notify.sh" ]; then
  "$HERE/notify.sh" "🧭 drift-watch: ${#issues[@]} source-of-truth drift issue(s)" "$(printf '%s\n' ${issues[@]+"${issues[@]}"} | head -12)" >/dev/null 2>&1 || true
fi
exit 0
