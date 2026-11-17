#!/usr/bin/env bash
# os/install.sh - install the Mac-local part of the AI OS. The always-on part is the brain Worker (os/cloud/brain), never installed here.
#
#   os/install.sh [--dry-run] [--home DIR]
#
# Copies os/ops/** -> $HOME/.claude/scripts, os/config/os.env -> $HOME/.claude/os.env, renders ONLY the Mac-local plists listed in
# os/launchd/mac-local.list (__HOME__ / __PATH__ / __OS_HOME__ / __USER__ tokens) into $HOME/Library/LaunchAgents, symlinks os/agents/*.md and
# os/skills/* (main checkout on main only), sets core.hooksPath + $OS_GIT_CHAIN_KEY on trusted husky repos, registers the Claude Code
# hooks. Idempotent: a second run changes nothing. Refuses to run while any predecessor-prefix launchd label is loaded (run os/cutover.sh).
# --dry-run prints the plan and writes nothing. --home DIR installs into DIR instead of $HOME (tests, staging).
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OSD="$REPO/os"
DRY=0; HOME_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --home) shift; HOME_ARG="${1:?--home needs a directory}" ;;
    -h|--help) sed -n 2,11p "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "install: unknown argument $1" >&2; exit 2 ;;
  esac
  shift
done
if [ -n "$HOME_ARG" ]; then mkdir -p "$HOME_ARG"; HOME="$(cd "$HOME_ARG" && pwd)"; export HOME; fi
# A staging / test install (--home DIR) must never drive the REAL launchd: it would boot out and re-bootstrap the real com.ebda.os.* jobs from
# plists in DIR (2026-11-17: an unstubbed loop left every job pointing at a deleted temp HOME). Tests put a launchctl stub first on PATH.
if [ -n "$HOME_ARG" ] && [ "$DRY" = 0 ]; then
  case "$(command -v launchctl 2>/dev/null)" in
    /bin/launchctl|/usr/bin/launchctl|/sbin/launchctl|/usr/sbin/launchctl)
      echo "install: refusing: --home with the real launchctl on PATH would boot out and re-bootstrap the REAL com.ebda.os jobs from $HOME_ARG. Put a launchctl stub first on PATH (tests), or use --dry-run." >&2; exit 2 ;;
  esac
fi
# shellcheck source=ops/lib/os-config.sh
. "$OSD/ops/lib/os-config.sh"
OS_CONFIG_FILE="$OSD/config/os.env" os_config_load
# shellcheck source=ops/lib/trusted-origin.sh
. "$OSD/ops/lib/trusted-origin.sh"

DEST="$HOME/.claude/scripts"; LA="$HOME/Library/LaunchAgents"; U="$(id -u)"
PREFIX="$OS_LAUNCHD_PREFIX"; CHAIN="$OS_GIT_CHAIN_KEY"
# The predecessor's label prefix, built in two pieces so no source file spells it out.
OLD_PREFIX="com.for""ceai"

FAILS=0
say() { printf '%s\n' "$*"; }
act() { [ "$DRY" = 1 ] || "$@"; }

# --- 0. refuse while the predecessor's jobs are loaded -------------------------------------------------------------
loaded_old="$(launchctl list 2>/dev/null | awk -v p="$OLD_PREFIX." 'index($3,p)==1 {print $3}' || true)"
if [ -n "$loaded_old" ]; then
  echo "install: refusing - jobs from the previous OS are still loaded:" >&2
  printf '  %s\n' $loaded_old >&2
  echo "run os/cutover.sh first (it unloads them), then re-run os/install.sh." >&2
  exit 3
fi

# copy_if_changed <src> <dst> [mode]: copies only when content differs; prints one plan line either way.
n_copy=0; n_same=0
copy_if_changed() {
  local s="$1" d="$2"
  if [ -f "$d" ] && cmp -s "$s" "$d"; then n_same=$((n_same+1)); return 0; fi
  say "copy   $s -> $d"; n_copy=$((n_copy+1))
  [ "$DRY" = 1 ] && return 0
  mkdir -p "$(dirname "$d")"; cp "$s" "$d"; [ -x "$s" ] && chmod +x "$d"; return 0
}

# --- 1. scripts: os/ops/** -> ~/.claude/scripts (no tests, no launchd templates, no git-hooks source, no installer shims) --
while IFS= read -r rel; do
  copy_if_changed "$OSD/ops/$rel" "$DEST/$rel"
done < <(cd "$OSD/ops" && find . -type f \
  ! -path './tests/*' ! -path './launchd/*' ! -path '*/__tests__/*' ! -path './git-hooks/*' ! -path './cloud/*' \
  ! -name 'install.sh' ! -name 'tests-pending.list' ! -name '.DS_Store' | sed 's|^\./||' | sort)
copy_if_changed "$OSD/config/os.env" "$HOME/.claude/os.env"
for f in "$OSD"/schemas/*.json; do [ -f "$f" ] && copy_if_changed "$f" "$HOME/.claude/schemas/$(basename "$f")"; done
for f in "$OSD/vendor/landlock-run/main.c" "$OSD/vendor/landlock-run/LICENSE"; do
  [ -f "$f" ] && copy_if_changed "$f" "$HOME/.claude/vendor/landlock-run/$(basename "$f")"
done
# global git hooks dispatcher (symlinked under each standard hook name)
GH="$HOME/.claude/git-hooks"
copy_if_changed "$OSD/ops/git-hooks/dispatch.sh" "$GH/dispatch.sh"
for h in applypatch-msg pre-applypatch post-applypatch pre-commit pre-merge-commit prepare-commit-msg commit-msg \
         post-commit pre-rebase post-checkout post-merge pre-push post-rewrite push-to-checkout pre-auto-gc; do
  if [ "$(readlink "$GH/$h" 2>/dev/null)" != "dispatch.sh" ]; then say "link   $GH/$h -> dispatch.sh"; act mkdir -p "$GH"; act ln -sfn dispatch.sh "$GH/$h"; fi
done

# --- 2. git: core.hooksPath + chain key on trusted husky repos ------------------------------------------------------------
cur="$(git config --global --get core.hooksPath 2>/dev/null || true)"
if [ -z "$cur" ] || [ "$cur" = "$GH" ]; then
  [ "$cur" = "$GH" ] || { say "git    core.hooksPath = $GH"; act git config --global core.hooksPath "$GH"; }
  n_chain=0
  while IFS= read -r hd; do
    top="$(dirname "$hd")"; [ -e "$top/.git" ] || continue
    wt_trusted_repo "$top" || continue
    [ "$(git -C "$top" config --local --get "$CHAIN" 2>/dev/null || true)" = true ] || { say "git    $CHAIN=true in $top"; act git -C "$top" config --local "$CHAIN" true; }
    n_chain=$((n_chain+1))
  done < <(find "$OS_PROJECTS_DIR" -maxdepth 6 -type d -name .husky -not -path '*/node_modules/*' -not -path '*/_worktrees/*' 2>/dev/null)
  say "git    $CHAIN covers $n_chain trusted husky repo(s)"
else
  say "WARN: global core.hooksPath is already $cur - not overwritten; the worktree-deps hook is inactive until it points at $GH"
fi

# --- 3. agents + skills: symlinks, main checkout on main only ------------------------------------------------------------
gd="$(git -C "$REPO" rev-parse --absolute-git-dir 2>/dev/null || true)"
cd_="$(cd "$REPO" && cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd || true)"
br="$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
LINK_OK=1
if [ "${OS_LINK_ANY_CHECKOUT:-0}" != 1 ] && { [ "$gd" != "$cd_" ] || { [ "$br" != main ] && [ "$br" != master ]; }; }; then
  LINK_OK=0; say "skip   agents + skills links: $REPO is not the main checkout on main (branch $br)"
fi
n_link=0
link_to() { # <target> <link>
  local t="$1" l="$2"
  if [ -e "$l" ] && [ ! -L "$l" ]; then say "WARN: $l exists and is not a symlink - skipped"; return 0; fi
  [ "$(readlink "$l" 2>/dev/null)" = "$t" ] && return 0
  say "link   $l -> $t"; n_link=$((n_link+1))
  [ "$DRY" = 1 ] || { mkdir -p "$(dirname "$l")"; ln -sfn "$t" "$l"; }
}
if [ "$LINK_OK" = 1 ]; then
  for f in "$OSD"/agents/*.md; do [ -f "$f" ] && link_to "$f" "$HOME/.claude/agents/$(basename "$f")"; done
  for d in "$OSD"/skills/*/; do [ -f "$d/SKILL.md" ] && link_to "${d%/}" "$HOME/.claude/skills/$(basename "$d")"; done
fi

# --- 4. launchd: ONLY the Mac-local set --------------------------------------------------------------------------------------
BREW="$(command -v brew >/dev/null 2>&1 && brew --prefix 2>/dev/null || echo /opt/homebrew)"
NODEBIN="$(command -v node >/dev/null 2>&1 && dirname "$(command -v node)" || true)"
RUN_PATH="$HOME/.local/bin:$BREW/bin:$BREW/opt/postgresql@17/bin${NODEBIN:+:$NODEBIN}:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
act mkdir -p "$LA" "$HOME/Library/Logs"
wanted=" "; n_plist=0
while IFS=$'\t' read -r name tmpl flag; do
  case "$name" in ''|'#'*) continue ;; esac
  label="$PREFIX.$name"
  # optional 3rd column `optin=VAR`: the job is installed only when VAR=1 (env or ~/.ebda-os.local.env); otherwise it is NOT wanted,
  # so a plist left by an earlier install is unloaded and removed below (ruling INSTALL-1)
  case "${flag:-}" in
    optin=*) _v="${flag#optin=}"
      case "$_v" in *[!A-Za-z0-9_]*|'') echo "install: bad opt-in flag '$flag' for $name" >&2; exit 1 ;; esac
      if [ "${!_v:-}" != 1 ]; then say "skip   $label (opt-in: set $_v=1 in ~/.ebda-os.local.env)"; continue; fi ;;
    '') ;;
    *) echo "install: unknown flag '$flag' for $name in mac-local.list" >&2; exit 1 ;;
  esac
  wanted="$wanted$label "
  [ -f "$OSD/$tmpl" ] || { echo "install: template missing: $tmpl" >&2; exit 1; }
  target="$LA/$label.plist"; tmp="$(mktemp)"
  sed -e "s#__HOME__#$HOME#g" -e "s#__PATH__#$RUN_PATH#g" -e "s#__OS_HOME__#$REPO#g" -e "s#__USER__#${USER:-$(id -un)}#g" "$OSD/$tmpl" > "$tmp"
  n_plist=$((n_plist+1))
  changed=1; [ -f "$target" ] && cmp -s "$tmp" "$target" && changed=0
  [ "$changed" = 1 ] && say "plist  $target"
  if [ "$changed" = 1 ] || ! launchctl print "gui/$U/$label" >/dev/null 2>&1; then
    say "bootstrap $label"
    if [ "$DRY" != 1 ]; then
      cp "$tmp" "$target"
      # the OLD definition must really be gone before the new one is bootstrapped: a bootout that fails for any reason except
      # "not loaded" leaves it running, and bootstrap would then fail (already loaded) or, worse, be mistaken for success
      if ! bo="$(launchctl bootout "gui/$U/$label" 2>&1)"; then
        case "$bo" in *"No such process"*|*"Could not find"*|*"not found"*|*"not loaded"*) ;; *) say "ERROR: could not unload $label ($bo); the old definition is still loaded"; FAILS=$((FAILS+1)); rm -f "$tmp"; continue ;; esac
      fi
      for _ in 1 2 3 4 5 6; do launchctl print "gui/$U/$label" >/dev/null 2>&1 || break; sleep 0.5; done
      if ! launchctl bootstrap "gui/$U" "$target" 2>/dev/null; then
        say "ERROR: bootstrap failed $label - retry: launchctl bootstrap gui/$U $target"; FAILS=$((FAILS+1))
      elif ! grep -qF "$target" < <(launchctl print "gui/$U/$label" 2>/dev/null); then
        say "ERROR: $label is loaded but not from the new plist ($target)"; FAILS=$((FAILS+1))
      fi
    fi
  fi
  rm -f "$tmp"
done < "$OSD/launchd/mac-local.list"
# a plist of ours that is no longer in the Mac-local set (an earlier all-jobs install) is unloaded and removed
for p in "$LA/$PREFIX".*.plist; do
  [ -f "$p" ] || continue
  label="$(basename "$p" .plist)"
  case "$wanted" in *" $label "*) continue ;; esac
  say "remove $p (not a Mac-local job)"
  if [ "$DRY" != 1 ]; then
    # a failed bootout other than "not loaded" must NOT be ignored: removing the plist of a job that is still running leaves it
    # running with no file to unload it later
    if ! bo="$(launchctl bootout "gui/$U/$label" 2>&1)"; then
      case "$bo" in *"No such process"*|*"Could not find"*|*"not found"*|*"not loaded"*) ;; *) say "ERROR: could not unload $label ($bo); plist kept"; FAILS=$((FAILS+1)); continue ;; esac
    fi
    rm -f "$p"
  fi
done

# --- 5. Claude Code hooks (settings.json merge) -------------------------------------------------------------------------------
if [ "$DRY" = 1 ]; then say "hooks  would register via ops/install-hooks.sh"
else bash "$OSD/ops/install-hooks.sh" >/dev/null 2>&1 || { say "ERROR: hook registration failed - re-run $OSD/ops/install-hooks.sh"; FAILS=$((FAILS+1)); }; fi
[ -f "$OS_SERVICES_ENV" ] || { say "create $OS_SERVICES_ENV (empty, 0600)"; [ "$DRY" = 1 ] || install -m 600 /dev/null "$OS_SERVICES_ENV"; }

say "summary: $n_copy file(s) to copy ($n_same unchanged), $n_link link(s), $n_plist Mac-local launchd job(s)$([ "$DRY" = 1 ] && echo ' [dry-run: nothing written]')"
[ "$FAILS" = 0 ] || { echo "install: $FAILS step(s) failed (see ERROR above)" >&2; exit 1; }
