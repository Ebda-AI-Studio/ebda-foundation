#!/usr/bin/env bash
# Ebda foundation bump bot (Ruling FDN-DIST-1, plan business/ebda/plans/2026-10-26-ebda-foundation.md section 3). Mac-only, $0.
# For each consumer repo that is behind the latest ebda-foundation tag: worktree -> `ebda-foundation sync` -> parity test +
# typecheck under host-lock -> push -> ONE PR labelled foundation-bump (updated, never duplicated) -> Telegram note.
# It never merges and never rebases a repo while a merge train is running.
#
# OFF BY DEFAULT. It does nothing unless ~/.claude/ebda-foundation-bump.enabled exists AND a consumer has a foundation.lock.json
# (the consumers adopt the foundation at plan steps F2/F3). Without --apply it only reports what it would do.
# usage: ebda-foundation-bump.sh [--apply]      log: ~/Library/Logs/ebda-foundation-bump.log (launchd com.ebda.os.ebda-foundation-bump, 09:17)
set -uo pipefail
APPLY=0; [ "${1:-}" = "--apply" ] && APPLY=1
ROOT="${EBDA_ROOT:-$HOME/Desktop/projects/Ebda-AI-Studio/internal-projects}"
FOUNDATION="${EBDA_FOUNDATION_DIR:-$ROOT/ebda-foundation}"
ENABLED="${EBDA_BUMP_ENABLED_FILE:-$HOME/.claude/ebda-foundation-bump.enabled}"
TRAIN_FILE="${EBDA_TRAIN_FILE:-}"            # optional: a file containing the word RUNNING while a merge wave is in flight
SCRIPTS="${EBDA_SCRIPTS_DIR:-$HOME/.claude/scripts}"
CONSUMERS="${EBDA_CONSUMERS:-ebda-store:Whisky-11/ebda-store ebda-whatsapp:Whisky-11/ebda-whatsapp}"
log() { echo "$(date '+%F %T') ebda-foundation-bump: $*"; }

[ -f "$ENABLED" ] || { log "disabled (no $ENABLED); nothing to do"; exit 0; }
[ -d "$FOUNDATION/.git" ] || { log "no foundation checkout at $FOUNDATION"; exit 0; }
if [ -n "$TRAIN_FILE" ] && grep -q RUNNING "$TRAIN_FILE" 2>/dev/null; then log "a merge wave is running; waiting"; exit 0; fi

git -C "$FOUNDATION" fetch -q --tags origin || { log "fetch failed"; exit 1; }
latest="$(git -C "$FOUNDATION" tag -l 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname | head -1)"
[ -n "$latest" ] || { log "no foundation tag yet"; exit 0; }

for c in $CONSUMERS; do
  name="${c%%:*}"; slug="${c#*:}"; repo="$ROOT/$name"
  lock="$repo/foundation.lock.json"
  [ -f "$lock" ] || { log "$name: no foundation.lock.json (not adopted yet); skipped"; continue; }
  cur="$(node -p "require('$lock').tag")"
  if [ "$cur" = "$latest" ]; then log "$name: on $latest; nothing to do"; continue; fi
  open="$(gh pr list -R "$slug" --label foundation-bump --state open --json number --jq '.[0].number' 2>/dev/null)"
  log "$name: $cur -> $latest${open:+ (open bump PR #$open will be updated)}"
  [ "$APPLY" = 1 ] || continue
  branch="chore/foundation-$latest"
  wt="$("$SCRIPTS/new-task-worktree.sh" "$name" "$branch" 2>/dev/null | sed -n 's/^.*worktree: //p' | tail -1)"
  [ -d "$wt" ] || { log "$name: could not create a worktree"; continue; }
  bash "$SCRIPTS/wt-deps.sh" "$wt" >/dev/null 2>&1
  git -C "$FOUNDATION" checkout -q "$latest" || { log "$name: cannot check out $latest"; continue; }
  node "$FOUNDATION/bin/ebda-foundation.mjs" sync --target "$wt" --to "$latest" || { git -C "$FOUNDATION" checkout -q main; continue; }
  git -C "$FOUNDATION" checkout -q main
  if ! (cd "$wt" && bash "$FOUNDATION/ops/host-lock.sh" sh -c 'npx vitest run "$(node -p "require(\"./foundation.lock.json\").parity")" && npm run typecheck'); then
    log "$name: parity/typecheck failed on $latest; no PR"; continue
  fi
  git -C "$wt" add foundation.lock.json "$(node -p "require('$wt/foundation.lock.json').dir")" "$(node -p "require('$wt/foundation.lock.json').ops")" "$(node -p "require('$wt/foundation.lock.json').parity")"
  git -C "$wt" commit -q -m "chore(foundation): bump to $latest" && git -C "$wt" push -q -u origin "$branch"
  [ -n "$open" ] || gh pr create -R "$slug" --head "$branch" --label foundation-bump --title "chore(foundation): bump to $latest" --body "Automated bump from $cur to $latest by the foundation bump bot. See ebda-foundation CHANGELOG."
  [ -z "${TELEGRAM_NOTIFY:-}" ] || "$TELEGRAM_NOTIFY" "ebda-foundation $latest: bump PR for $name"
done
