#!/usr/bin/env bash
# Whisky AI OS — install the oversight runtime. DYNAMIC + PORTABLE.
#
# ops/ is the SOURCE. launchd cannot exec from ~/Desktop (macOS TCC), so runnable
# copies are installed into ~/.claude/scripts. This installer is:
#   - DYNAMIC: copies EVERY ops/*.sh (+ lib + assets + dashboard) and schedules
#     EVERY ops/launchd/*.plist. Add a script/plist to the repo → next run picks
#     it up. No hardcoded script list to keep in sync.
#   - PORTABLE: plists are stored as templates with __HOME__ / __PATH__ tokens.
#     This installer substitutes the CURRENT machine's home + a computed PATH, so
#     the OS moves to a Mac with a different username (e.g. the ForceAI Studio)
#     unchanged. Service tokens live in ~/.whisky-services.env (local, never git).
# shellcheck source=lib/os-config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/os-config.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-config.sh" 2>/dev/null || true
command -v os_config_load >/dev/null 2>&1 && os_config_load
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"; DEST="$HOME/.claude/scripts"
mkdir -p "$DEST/lib" "$DEST/detectors" "$DEST/journeys" "$DEST/dashboard/public" "$DEST/remediation" "$DEST/watchers" "$DEST/hooks" "$HOME/Library/LaunchAgents"

# --- 1. scripts: copy EVERY ops/*.sh (dynamic — no maintained list) ---
n_scripts=0
for f in "$SRC/"*.sh; do
  b="$(basename "$f")"
  cp "$f" "$DEST/$b"; chmod +x "$DEST/$b"; n_scripts=$((n_scripts+1))
done
# helpers + engines + runtime assets scripts read relative to themselves
# identity/paths for every script (lib/os-config.sh finds it at ~/.claude/os.env once installed)
[ -f "$SRC/../config/os.env" ] && cp "$SRC/../config/os.env" "$HOME/.claude/os.env"
cp "$SRC/lib/"*.sh "$DEST/lib/" 2>/dev/null || true
cp "$SRC/lib/"*.py "$DEST/lib/" 2>/dev/null || true
cp "$SRC/lib/"*.json "$DEST/lib/" 2>/dev/null || true   # heal-registry.json etc.
cp "$SRC/lib/"*.mjs "$DEST/lib/" 2>/dev/null || true    # sitemap-urls.mjs (page-load-monitor)
cp "$SRC/lib/"*.tsv "$DEST/lib/" 2>/dev/null || true    # projects-layout.pending.tsv
cp "$SRC/remediation/"*.sh "$DEST/remediation/" 2>/dev/null || true   # classify/registry/ledger/gate/review-score
cp "$SRC/watchers/"*.sh "$DEST/watchers/" 2>/dev/null || true
cp "$SRC/hooks/"*.sh "$DEST/hooks/" 2>/dev/null || true   # PreToolUse guards; registered by install-hooks.sh
mkdir -p "$DEST/../schemas"; cp "$SRC/../schemas/"*.json "$DEST/../schemas/" 2>/dev/null || true   # validate-hooks.sh resolves ../schemas
# Landlock launcher: SOURCE only. It is deliberately NOT built here — this installer
# runs on macOS, where Landlock does not exist, and shipping an unbuildable binary
# path would make sandbox_run's probe fail in a confusing way. Build it on the Linux
# guests at image time: ops/build-landlock.sh
mkdir -p "$DEST/../vendor/landlock-run"
cp "$SRC/../vendor/landlock-run/main.c" "$SRC/../vendor/landlock-run/LICENSE" "$DEST/../vendor/landlock-run/" 2>/dev/null || true
chmod +x "$DEST/hooks/"*.sh 2>/dev/null || true
   # findings-watch / service-probe / runner-heartbeat
cp "$SRC/detectors/"*.json "$DEST/detectors/" 2>/dev/null || true
cp -R "$SRC/journeys/"* "$DEST/journeys/" 2>/dev/null || true   # -R so journeys/page-load/ subdir travels too
# dashboard (zero-dep node app) travels whole so server + aggregator + public/ stay together
cp "$SRC/dashboard/server.mjs" "$SRC/dashboard/state-aggregator.mjs" "$DEST/dashboard/" 2>/dev/null || true
cp "$SRC/dashboard/public/index.html" "$DEST/dashboard/public/" 2>/dev/null || true
echo "installed $n_scripts scripts + lib/detectors/journeys/dashboard/hooks into $DEST"

# --- 1a. global git hooks (worktree dependency cache for EVERY tool that creates a worktree) ---
# ONE dispatcher, symlinked as each standard hook name, activated through the global core.hooksPath. post-checkout
# runs wt-deps.sh on a NEW linked worktree (raw `git worktree add`, EnterWorktree, Agent isolation, Codex ...);
# every hook chains to the repo's own (.git/hooks or .husky) so repo hooks keep working. Never clobbers a
# core.hooksPath that points somewhere else - it warns instead.
GH="$HOME/.claude/git-hooks"; mkdir -p "$GH"
cp "$SRC/git-hooks/dispatch.sh" "$GH/dispatch.sh"; chmod +x "$GH/dispatch.sh"
for h in applypatch-msg pre-applypatch post-applypatch pre-commit pre-merge-commit prepare-commit-msg commit-msg \
         post-commit pre-rebase post-checkout post-merge pre-push post-rewrite push-to-checkout pre-auto-gc; do
  ln -sfn dispatch.sh "$GH/$h"
done
_cur="$(git config --global --get core.hooksPath 2>/dev/null || true)"
if [ -z "$_cur" ] || [ "$_cur" = "$GH" ]; then
  git config --global core.hooksPath "$GH"; echo "global git hooks: core.hooksPath = $GH (dispatcher + $(ls "$GH" | wc -l | tr -d ' ') entries)"
  # husky chaining is OPT-IN per repo (tracked content must never run for an untrusted clone): enable it for Ahmad's own
  # repos only - origin in his orgs AND under $OS_PROJECTS_DIR.
  # shellcheck source=lib/trusted-origin.sh
  _n=0; . "$SRC/lib/trusted-origin.sh"
  while IFS= read -r hd; do
    top="$(dirname "$hd")"; [ -e "$top/.git" ] || continue
    wt_trusted_repo "$top" || continue
    git -C "$top" config --local "${OS_GIT_CHAIN_KEY:-ebda.chainHusky}" true && _n=$((_n+1))
  done < <(find "$OS_PROJECTS_DIR" -maxdepth 6 -type d -name .husky -not -path '*/node_modules/*' -not -path '*/_worktrees/*' 2>/dev/null)
  echo "  ${OS_GIT_CHAIN_KEY:-ebda.chainHusky}=true set on $_n of Ahmad's husky repos (opt-in; all other repos never run tracked hooks globally)"
else
  echo "  WARN: global core.hooksPath is already $_cur - NOT overwritten; worktree-deps git hook is INACTIVE. Point it at $GH (or chain to $GH/dispatch.sh) to enable."
fi

# --- 1b. skills: SYMLINK each repo skills/<name>/ into ~/.claude/skills/<name> ---
# Symlink, not copy: the repo stays the single source, so a merged skill edit needs no re-install.
# Dynamic: every dir under skills/ holding a SKILL.md. Never clobbers a real dir (a
# hand-installed skill of the same name) — it warns and skips. force-audit is excluded by
# default (install decision still open, docs/plans/HANDOFF-force-audit.md); opt in with
# SKILLS_EXCLUDE="" ops/install.sh.
# Trust boundary: a symlink makes whatever is checked out LIVE in every session. So link
# only from the main checkout on master/main, never a linked worktree or a feature branch
# (unreviewed text would go live, and the link dangles once the worktree is cleaned).
# Override for tests only: OS_LINK_ANY_CHECKOUT=1.
_repo="$(cd "$SRC/.." && pwd)"
_gd="$(git -C "$_repo" rev-parse --absolute-git-dir 2>/dev/null)"; _cd="$(cd "$_repo" && cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd)"
_br="$(git -C "$_repo" rev-parse --abbrev-ref HEAD 2>/dev/null)"
SKILLS_LINK_OK=1
if [ "${OS_LINK_ANY_CHECKOUT:-0}" != 1 ] && { [ "$_gd" != "$_cd" ] || { [ "$_br" != master ] && [ "$_br" != main ]; }; }; then
  SKILLS_LINK_OK=0; echo "  SKIP skills link: $_repo is not the main checkout on master/main (branch $_br) — run install.sh from the main checkout"
fi
SKILLS_DEST="$HOME/.claude/skills"; SKILLS_EXCLUDE="${SKILLS_EXCLUDE-force-audit}"; n_skills=0
mkdir -p "$SKILLS_DEST"
[ "$SKILLS_LINK_OK" = 1 ] && for d in "$SRC/../skills/"*/; do
  [ -f "$d/SKILL.md" ] || continue
  name="$(basename "$d")"
  case " $SKILLS_EXCLUDE " in *" $name "*) continue ;; esac
  link="$SKILLS_DEST/$name"
  if [ -e "$link" ] && [ ! -L "$link" ]; then
    echo "  WARN: $link exists and is not a symlink — skipped, not overwritten (remove it by hand to link skills/$name)"
    continue
  fi
  ln -sfn "$(cd "$d" && pwd)" "$link"; n_skills=$((n_skills+1))
done
echo "linked $n_skills skill(s) into $SKILLS_DEST"
# Copying a hook is not installing it. Registration lives in settings.json and is a
# SEPARATE step; skipping it is how ops/self-eval-gate.sh shipped and never fired.
echo "next: ops/install-hooks.sh   (registers the PreToolUse/Stop hooks in ~/.claude/settings.json)"

# --- optional: Playwright for page-load-monitor Layer 2 (opt-in; heavy ~200MB) ---
# fleet-deep.mjs does import("playwright"), so the PACKAGE must be resolvable from
# $DEST (node walks up to $DEST/node_modules). Without it Layer 2 fails-open (skips).
if [ "${INSTALL_PLAYWRIGHT:-0}" = "1" ]; then
  echo "installing Playwright + chromium for page-load-monitor Layer 2 (INSTALL_PLAYWRIGHT=1)…"
  ( cd "$DEST" && { [ -f package.json ] || npm init -y -q >/dev/null 2>&1; } \
    && npm i playwright@latest >/dev/null 2>&1 && npx --yes playwright install chromium >/dev/null 2>&1 \
    && echo "  Playwright ready — page-load-monitor Layer 2 active" ) \
    || echo "  WARN: Playwright install failed — Layer 2 will skip (fail-open). Retry: cd $DEST && npm i playwright && npx playwright install chromium"
else
  echo "note: page-load-monitor Layer 2 (Playwright) not installed — re-run with INSTALL_PLAYWRIGHT=1 to enable (see docs/runbooks/page-load-monitor.md); Layer 1 runs regardless"
fi

[ -f "$OS_SERVICES_ENV" ] || { install -m 600 /dev/null "$OS_SERVICES_ENV"; echo "created empty ~/.whisky-services.env (add tokens to activate probes)"; }

# --- 2. compute a machine-appropriate PATH for the plist __PATH__ token ---
BREW="$(command -v brew >/dev/null 2>&1 && brew --prefix 2>/dev/null || echo /opt/homebrew)"
PG17="$( (command -v brew >/dev/null 2>&1 && brew --prefix postgresql@17 2>/dev/null) || echo "$BREW/opt/postgresql@17")"
NODEBIN="$(command -v node >/dev/null 2>&1 && dirname "$(command -v node)" || true)"
# /usr/local/bin is where umbra installs. Leaving it out cost the runner guard its
# entire fleet check: `command -v umbra` failed under launchd while working fine in
# an interactive shell, so the guard reported "could not check" every run.
RUN_PATH="$HOME/.local/bin:$BREW/bin:$PG17/bin${NODEBIN:+:$NODEBIN}:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
echo "computed launchd PATH: $RUN_PATH"

# --- 3. install + (re)schedule EVERY plist, substituting the machine's home+PATH ---
# launchctl bootout returns BEFORE teardown completes, so wait for the service to
# disappear then retry bootstrap (without this a random job is left unloaded).
U=$(id -u); warned=0; n_jobs=0
for tmpl in "$SRC/launchd/"${OS_LAUNCHD_PREFIX}.*.plist; do
  [ -f "$tmpl" ] || continue
  label=$(basename "$tmpl" .plist)
  target="$HOME/Library/LaunchAgents/$label.plist"
  sed -e "s#__HOME__#$HOME#g" -e "s#__PATH__#$RUN_PATH#g" "$tmpl" > "$target"
  launchctl bootout "gui/$U/$label" 2>/dev/null || true
  for _ in 1 2 3 4 5 6; do launchctl print "gui/$U/$label" >/dev/null 2>&1 || break; sleep 0.5; done
  ok=0
  for _ in 1 2 3; do
    launchctl bootstrap "gui/$U" "$target" 2>/dev/null && { ok=1; break; }
    launchctl print "gui/$U/$label" >/dev/null 2>&1 && { ok=1; break; }
    sleep 1
  done
  n_jobs=$((n_jobs+1))
  if [ "$ok" = 1 ]; then echo "  scheduled $label"; else warned=1; echo "  WARN: bootstrap failed $label — retry: launchctl bootstrap gui/$U \"$target\""; fi
done

if [ "$warned" = 1 ]; then
  echo "installed $n_jobs jobs; SOME failed to bootstrap (see WARN) — re-run ops/install.sh or the printed command."
else
  echo "installed + scheduled all $n_jobs ${OS_LAUNCHD_PREFIX}.* jobs (runtime in ~/.claude/scripts)."
fi
echo "Verify: ops/self-check.sh (Check 2.5 = TCC guard). Report via the Whisky Whoop bot."

# === BEGIN agents symlink step (feat/auditor-diff-mode) — keep this block self-contained ===
# agents/*.md are the source of truth; link them into ~/.claude/agents/. A differing
# real file is moved to ~/.claude/agents/.pre-foundation-backup/, never overwritten.
if [ -x "$SRC/install-agents.sh" ] && [ -d "$SRC/../agents" ]; then
  "$SRC/install-agents.sh" || echo "WARN: agents symlink step failed (see above) — re-run ops/install-agents.sh"
fi
# === END agents symlink step ===
