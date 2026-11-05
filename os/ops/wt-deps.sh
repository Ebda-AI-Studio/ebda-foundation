#!/usr/bin/env bash
# wt-deps.sh — shared dependency cache for git worktrees, using APFS copy-on-write clones.
#
# WHY (2026-10-24, 3rd disk-full incident class): every agent worktree ran its own `npm ci`
# (~2 GB node_modules each), 6 parallel agents filled the Mac disk, and a full host disk corrupts the
# Umbra CI VM guest (feedback-umbra-sparse-disk-host-full-corrupts-guest). Now ONE install per lockfile
# lives in ~/.cache/wt-deps and every worktree gets a `cp -cR` clonefile copy: near-zero disk until a
# file is written. node_modules is NEVER symlinked (tools resolve real paths and break).
#
# Usage: wt-deps.sh [--check] [worktree-dir]   (default: cwd; runs standalone in any existing worktree)
#   --check   install nothing: exit 0 when a COMPLETE cache entry exists for this lockfile (a "cache hit"), else 1.
#             Used by hooks/block-worktree-install.sh to tell an agent "clone, don't npm ci" ONLY on a real hit.
#   WT_DEPS_CACHE=<dir>   cache root (default ~/.cache/wt-deps)
#   WT_DEPS_KEEP=<n>      keys kept per repo (default 2, newest by creation)
#   WT_DEPS_FORCE=1       replace an existing non-empty node_modules with the clone
#   WT_DEPS_HOOK=1        HOOK MODE, set by the automatic callers (global git post-checkout, Claude PostToolUse). Those
#                         fire on repos nobody chose, so it is CLONE-ONLY and TRUSTED-ONLY: (1) origin must be an exact
#                         github.com URL of Whisky-11/Ebda-AI-Studio/voidengineer-911 (lib/trusted-origin.sh) AND the worktree's
#                         real path under ~/Desktop/projects, else exit 0 doing nothing; (2) it only clones an existing
#                         cache entry (built by a deliberate install); a cache MISS prints the manual command and exits 0 -
#                         it never runs npm/pnpm/yarn (their lockfile/.npmrc/registry/pnpmfile/yarnPath are repo-controlled
#                         code paths); (3) no husky re-arm (that would execute dependency code).
#
# Key = sha256(lockfile + package.json + origin url)[:16] + node major + arch. Cache entry = <repo>/<key>/tree/<relpath>/node_modules
# for the root AND every workspace's nested node_modules, snapshotted (cloned) from a real install.
# Miss -> install once in THIS worktree (npm ci | pnpm --frozen-lockfile | yarn --frozen-lockfile),
# snapshot, prune. Non-APFS / cross-volume cache -> plain install, no cache.
set -uo pipefail
CHECK=0; if [ "${1:-}" = "--check" ]; then CHECK=1; shift; fi
WT="$(cd "${1:-.}" && pwd -P)" || { echo "wt-deps: bad dir" >&2; exit 2; }
CACHE_ROOT="${WT_DEPS_CACHE:-$HOME/.cache/wt-deps}"
KEEP="${WT_DEPS_KEEP:-2}"
log() { echo "wt-deps: $*" >&2; }

[ -f "$WT/package.json" ] || { [ "$CHECK" = 1 ] && exit 1; log "no package.json in $WT - nothing to do"; exit 0; }

# hook mode: trust gate (see header). One validator shared with the git hook dispatcher and install.sh.
IGN=""
if [ "${WT_DEPS_HOOK:-0}" = 1 ] && [ "$CHECK" = 0 ]; then
  . "$(dirname "${BASH_SOURCE[0]}")/lib/trusted-origin.sh" 2>/dev/null || { log "hook mode: trusted-origin lib missing - NOT installing"; exit 0; }
  if ! wt_trusted_repo "$WT"; then
    log "hook mode: $WT is not a trusted repo (origin '$(git -C "$WT" config --get remote.origin.url 2>/dev/null)') - NOT installing deps automatically"; exit 0
  fi
  IGN=1   # hook mode is CLONE-ONLY: see the cache-miss rule below; no installer ever runs from a hook
fi

# lockfile -> installer
if   [ -f "$WT/package-lock.json" ]; then LOCK=package-lock.json; INSTALL=(npm ci)
elif [ -f "$WT/pnpm-lock.yaml" ];    then LOCK=pnpm-lock.yaml;    INSTALL=(pnpm install --frozen-lockfile)
elif [ -f "$WT/yarn.lock" ];         then LOCK=yarn.lock;         INSTALL=(yarn install --frozen-lockfile)
elif [ "$CHECK" = 1 ]; then exit 1
elif [ -n "$IGN" ]; then log "hook mode: no lockfile - nothing to clone"; exit 0
else log "no lockfile - plain 'npm install'"; (cd "$WT" && npm install); exit $?; fi

# repo name = the MAIN repo's dir name (shared by all its worktrees)
common="$(git -C "$WT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
if [ -n "$common" ]; then REPO="$(basename "$(dirname "$common")")"; else REPO="$(basename "$WT")"; fi
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo x)"
# key = lockfile + root package.json (its lifecycle scripts shape node_modules) + origin url (no cross-repo sharing)
HASH="$( { cat "$WT/$LOCK" "$WT/package.json"; git -C "$WT" config --get remote.origin.url 2>/dev/null; } | shasum -a 256 | cut -c1-16)"
KEY="${HASH}-n${NODE_MAJOR}-$(uname -m)"
RCACHE="$CACHE_ROOT/$REPO"; ENTRY="$RCACHE/$KEY"
if [ "$CHECK" = 1 ]; then [ -f "$ENTRY/.complete" ]; exit $?; fi
[ -n "$IGN" ] && INSTALL=(false)   # belt and braces: even a missed guard cannot run npm/pnpm/yarn from a hook
# hook mode never installs (an install runs lockfile/.npmrc/registry-controlled code): on a cache MISS it stops here
if [ -n "$IGN" ] && [ ! -f "$ENTRY/.complete" ]; then
  log "hook mode: no cache entry for $REPO/$KEY - NOT installing automatically. Run once by hand: bash ~/.claude/scripts/wt-deps.sh $WT"; exit 0
fi

plain_install() {
  # hook mode NEVER installs - every fallback (mkdir/probe/lock-timeout/clone failure) lands here
  [ -n "$IGN" ] && { log "hook mode: clone path failed - NOT installing; run by hand: bash ~/.claude/scripts/wt-deps.sh $WT"; exit 0; }
  log "falling back to a normal install in $WT"; (cd "$WT" && "${INSTALL[@]}"); }

# already installed here? (leave a real install alone unless forced)
if [ -d "$WT/node_modules" ] && [ -n "$(ls -A "$WT/node_modules" 2>/dev/null)" ] && [ "${WT_DEPS_FORCE:-0}" != 1 ]; then
  log "$WT/node_modules already populated (WT_DEPS_FORCE=1 to replace) - skipping"; exit 0
fi

# nested node_modules dirs of a tree, relative, never descending into node_modules (workspaces live <=4 deep).
# SECURITY: NUL-separated (a newline in a dir name cannot forge a second path); names with a newline, a '..' segment, a
# leading '/' or not ending in node_modules are dropped; find -type d never lists a SYMLINK, and safe_rel additionally
# requires every parent to resolve (pwd -P) inside the real $WT with no symlink escape.
safe_rel() {   # $1 = base dir (real path), $2 = rel
  local base="$1" rel="$2" par
  case "$rel" in *$'\n'*|/*|..|../*|*/..|*/../*) return 1 ;; esac
  case "$rel" in node_modules|*/node_modules) ;; *) return 1 ;; esac
  [ -L "$base/$rel" ] && return 1
  par="$(cd "$base/$(dirname "$rel")" 2>/dev/null && pwd -P)" || return 1
  case "$par/" in "$base"/*) return 0 ;; *) return 1 ;; esac
}
list_nm() { local base rel; base="$(cd "$1" && pwd -P)"
  while IFS= read -r -d '' rel; do rel="${rel#./}"; safe_rel "$base" "$rel" && printf '%s\n' "$rel"
  done < <(cd "$1" && find . -maxdepth 5 -type d -name node_modules -not -path '*/node_modules/*' -not -path './.git/*' -prune -print0); }

# APFS clonefile support between cache and worktree (same volume + APFS): probe with a 1-byte file
mkdir -p "$RCACHE" 2>/dev/null || { plain_install; exit $?; }
probe_ok() {
  local a="$RCACHE/.probe.$$" b="$WT/.wt-deps-probe.$$"
  echo x > "$a" && cp -c "$a" "$b" 2>/dev/null; local rc=$?
  rm -f "$a" "$b"; return $rc
}
probe_ok || { log "clonefile unsupported between $RCACHE and $WT (not APFS / different volume)"; plain_install; exit $?; }

clone_in() {   # clone cached tree into $WT
  local n=0 rel pre _parts _c
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    case "$rel" in *..*|/*) log "refusing manifest entry '$rel'"; return 1 ;; esac
    # no symlink component anywhere on the way in (mkdir -p would follow a tracked symlink out of the worktree)
    pre=""; IFS=/ read -r -a _parts <<< "$(dirname "$rel")"
    for _c in ${_parts[@]+"${_parts[@]}"}; do [ "$_c" = . ] && continue; pre="$pre/$_c"; [ -L "$WT$pre" ] && { log "refusing symlinked parent $pre"; return 1; }; done
    mkdir -p "$WT/$(dirname "$rel")"
    safe_rel "$WT" "$rel" || [ ! -e "$WT/$rel" ] || { log "refusing unsafe path $rel"; return 1; }
    rm -rf "${WT:?}/$rel"
    cp -cR "$ENTRY/tree/$rel" "$WT/$rel" || return 1
    n=$((n+1))
  done < "$ENTRY/manifest"
  log "cloned $n node_modules dir(s) from cache $KEY into $WT"
}

lock_dir="$RCACHE/.lock-$KEY"
if [ ! -f "$ENTRY/.complete" ]; then
  # one builder per key; others wait (stale lock after 20 min is broken)
  waited=0
  until mkdir "$lock_dir" 2>/dev/null; do
    [ -f "$ENTRY/.complete" ] && break
    if [ -n "$(find "$lock_dir" -maxdepth 0 -mmin +20 2>/dev/null)" ]; then rmdir "$lock_dir" 2>/dev/null; continue; fi
    sleep 3; waited=$((waited+3)); [ "$waited" -gt 1500 ] && { log "lock wait timeout"; plain_install; exit $?; }
  done
  if [ ! -f "$ENTRY/.complete" ]; then
    trap 'rmdir "$lock_dir" 2>/dev/null' EXIT
    log "cache MISS $REPO/$KEY - installing once in $WT"
    rm -rf "${WT:?}/node_modules"
    if ! (cd "$WT" && "${INSTALL[@]}"); then log "install failed"; exit 1; fi
    part="$RCACHE/.partial-$KEY-$$"; rm -rf "$part"; mkdir -p "$part/tree"
    list_nm "$WT" > "$part/manifest"
    ok=1
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      mkdir -p "$part/tree/$(dirname "$rel")"
      cp -cR "$WT/$rel" "$part/tree/$rel" || { ok=0; break; }
    done < "$part/manifest"
    if [ "$ok" = 1 ] && [ -s "$part/manifest" ]; then
      date -u +%FT%TZ > "$part/.complete"; rm -rf "$ENTRY"; mv "$part" "$ENTRY"
      log "cache entry written: $ENTRY ($(wc -l < "$ENTRY/manifest" | tr -d ' ') node_modules dirs)"
    else rm -rf "$part"; log "snapshot failed - this worktree keeps its own install"; fi
    rmdir "$lock_dir" 2>/dev/null; trap - EXIT
    # prune: keep the KEEP newest complete entries (by creation marker)
    # (2026-10-25: the old `ls -1t -- */` printed "dir:" headers + a BLANK line once 2+ keys existed; the blank line made
    # `rm -rf "$RCACHE/"` wipe the WHOLE repo cache, including the entry just built. List only <key>/.complete markers.)
    (cd "$RCACHE" && ls -1t -- */.complete 2>/dev/null | sed 's#/\.complete$##') | tail -n +$((KEEP+1)) | while IFS= read -r old; do
      [ -n "$old" ] && [ "$old" != "$KEY" ] || continue; log "prune $REPO/$old"; rm -rf "${RCACHE:?}/${old:?}"; done
    exit 0   # this worktree already holds the fresh install
  fi
fi

if clone_in; then
  touch "$ENTRY/.complete"
  # husky's `prepare` never ran in a clone, so its (gitignored) .husky/_ stubs are missing and the repo's
  # git hooks (pre-commit/commit-msg/pre-push) would silently not fire in this worktree. Re-run husky (offline, instant).
  # NOT in hook mode: it would execute dependency code (that is what --ignore-scripts exists to prevent).
  if [ -z "$IGN" ] && [ -x "$WT/node_modules/.bin/husky" ] && grep -q '"husky' "$WT/package.json" 2>/dev/null && [ ! -d "$WT/.husky/_" ]; then
    (cd "$WT" && node_modules/.bin/husky >/dev/null 2>&1) && log "husky hooks re-armed in $WT" || log "WARN: husky re-arm failed in $WT"
  fi
  exit 0
fi
log "clone failed"; plain_install
