#!/usr/bin/env bash
# wt-deps.sh — shared dependency cache for git worktrees, using APFS copy-on-write clones.
#
# WHY (2026-10-24, 3rd disk-full incident class): every agent worktree ran its own `npm ci`
# (~2 GB node_modules each), 6 parallel agents filled the Mac disk, and a full host disk corrupts the
# CI runners sharing the disk. Now ONE install per lockfile
# lives in ~/.cache/wt-deps and every worktree gets a `cp -cR` clonefile copy: near-zero disk until a
# file is written. node_modules is NEVER symlinked (tools resolve real paths and break).
#
# Usage: wt-deps.sh [--check] [worktree-dir]   (default: cwd; runs standalone in any existing worktree)
#   --check   install nothing: exit 0 when a COMPLETE cache entry exists for this lockfile (a "cache hit"), else 1.
#             Used by hooks/block-worktree-install.sh to tell an agent "clone, don't npm ci" ONLY on a real hit.
#   OS_DEPS_CACHE=<dir>   cache root (default <SSD>/.cache/wt-deps when /Volumes/Ebda is mounted, else ~/.cache/wt-deps);
#                         WT_DEPS_CACHE is the legacy alias
#   WT_DEPS_KEEP=<n>      keys kept per repo (default 2, newest by creation)
#   WT_DEPS_FORCE=1       replace an existing non-empty node_modules with the clone
#   WT_DEPS_REFRESH=1     rebuild this key's cache entry from a fresh install (+ prisma generate) in THIS worktree; the only
#                         supported way to replace a poisoned entry (never hand-delete cache dirs). Not honoured in hook mode.
#   Prisma (2026-11-11): a repo with a prisma schema must end with a GENERATED client. `prisma generate` is not part of
#   `npm ci`, so a cache built before it ran held a ~2 KB placeholder client (Prisma.Decimal undefined -> ebda-store
#   customer-auth-backup.test.ts failed with "reading 'isDecimal'"). After every install/clone (never in hook mode: generate
#   runs repo code) a missing or stub (< WT_DEPS_PRISMA_MIN_BYTES, default 10000) node_modules/.prisma/client/index.d.ts is
#   regenerated with `npm run db:generate` (else `npx --no-install prisma generate`), and a fresh cache entry is generated
#   BEFORE it is snapshotted. WT_DEPS_PRISMA_GENERATE=0 disables.
#   Workspace outputs (same date): a package with a `build` script whose main/module/types/exports target is a missing,
#   git-ignored file (packages/database/dist) is built (`npm run build` in its dir, failures retried once for ordering)
#   after the same install/clone points, never in hook mode. WT_DEPS_BUILD_WORKSPACES=0 disables.
#   WT_DEPS_HOOK=1        HOOK MODE, set by the automatic callers (global git post-checkout, Claude PostToolUse). Those
#                         fire on repos nobody chose, so it is CLONE-ONLY and TRUSTED-ONLY: (1) origin must be an exact
#                         github.com URL of one of $OS_ORGS (lib/trusted-origin.sh) AND the worktree's
#                         real path under $OS_PROJECTS_DIR, else exit 0 doing nothing; (2) it only clones an existing
#                         cache entry (built by a deliberate install); a cache MISS prints the manual command and exits 0 -
#                         it never runs npm/pnpm/yarn (their lockfile/.npmrc/registry/pnpmfile/yarnPath are repo-controlled
#                         code paths); (3) no husky re-arm (that would execute dependency code).
#
# Key = sha256(lockfile + package.json + origin url)[:16] + node major + arch. Cache entry = <repo>/<key>/tree/<relpath>/node_modules
# for the root AND every workspace's nested node_modules, snapshotted (cloned) from a real install.
# Miss -> install once in THIS worktree (npm ci | pnpm --frozen-lockfile | yarn --frozen-lockfile),
# snapshot, prune. Non-APFS / cross-volume cache -> plain install, no cache.
# shellcheck source=lib/os-config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/os-config.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-config.sh" 2>/dev/null || true
command -v os_config_load >/dev/null 2>&1 && os_config_load
set -uo pipefail
CHECK=0; if [ "${1:-}" = "--check" ]; then CHECK=1; shift; fi
WT="$(cd "${1:-.}" && pwd -P)" || { echo "wt-deps: bad dir" >&2; exit 2; }
. "$(dirname "${BASH_SOURCE[0]}")/lib/wt-roots.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/wt-roots.sh" 2>/dev/null || true
# Cache root: OS_DEPS_CACHE > WT_DEPS_CACHE (legacy) > <SSD>/.cache/wt-deps > ~/.cache/wt-deps (lib/wt-roots.sh).
# Worktrees and cache must share a volume for APFS clones; across volumes probe_ok fails and it plain-installs.
if command -v wt_cache_root >/dev/null 2>&1; then CACHE_ROOT="$(wt_cache_root)"; else CACHE_ROOT="${WT_DEPS_CACHE:-$HOME/.cache/wt-deps}"; fi
KEEP="${WT_DEPS_KEEP:-2}"
log() { echo "wt-deps: $*" >&2; }

[ -f "$WT/package.json" ] || { [ "$CHECK" = 1 ] && exit 1; log "no package.json in $WT - nothing to do"; exit 0; }

# Prisma client guarantee (see header). $1 = worktree root. Returns 0 when nothing to do or generated, 1 when generate failed.
prisma_client_ok() {
  local wt="$1" idx="$1/node_modules/.prisma/client/index.d.ts" min="${WT_DEPS_PRISMA_MIN_BYTES:-10000}" size
  size="$( [ -f "$idx" ] && wc -c < "$idx" | tr -d ' ' || echo 0 )"
  [ "$size" -ge "$min" ]
}
has_prisma_schema() {
  [ -n "$(cd "$1" && find . -maxdepth 4 -name schema.prisma -not -path '*/node_modules/*' -not -path './.git/*' 2>/dev/null | head -1)" ]
}
ensure_prisma_client() {
  local wt="$1"
  [ "${WT_DEPS_PRISMA_GENERATE:-1}" = 0 ] && return 0
  has_prisma_schema "$wt" || return 0
  prisma_client_ok "$wt" && return 0
  log "prisma client missing or a stub in $wt - generating"
  if grep -q '"db:generate"' "$wt/package.json" 2>/dev/null; then (cd "$wt" && npm run db:generate >&2)
  else (cd "$wt" && npx --no-install prisma generate >&2); fi
  prisma_client_ok "$wt" || { log "WARN: prisma generate did not produce a real client in $wt"; return 1; }
  log "prisma client generated in $wt"
}

# Workspace build outputs (2026-11-11): a workspace package whose main/module/types/exports point at a git-IGNORED file
# (packages/database/dist/index.js) has nothing there in a clone - node_modules snapshots do not carry dist/. Lists
# "<package dir>" for each package with a `build` script and at least one missing, ignored entry target.
missing_workspace_builds() {
  local wt="$1" d
  while IFS= read -r -d '' f; do
    d="$(dirname "$f")"; [ "$d" = "." ] && continue
    node -e '
      const fs=require("fs"),p=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
      if(!p.scripts||!p.scripts.build)process.exit(0);
      const t=[];const walk=v=>{if(typeof v==="string")t.push(v);else if(v&&typeof v==="object")Object.values(v).forEach(walk)};
      ["main","module","types","typings"].forEach(k=>walk(p[k]));walk(p.exports);
      for(const x of t){if(/^\.\/?[^*]+$/.test(x)||/^[^.*][^*]*$/.test(x)){console.log(x.replace(/^\.\//,""))}}
    ' "$wt/$f" 2>/dev/null | while IFS= read -r tgt; do
      [ -n "$tgt" ] || continue
      case "$tgt" in *..*|/*) continue ;; esac
      [ -e "$wt/$d/$tgt" ] && continue
      git -C "$wt" check-ignore -q -- "$d/$tgt" 2>/dev/null && { echo "$d"; break; }
    done
  done < <(cd "$wt" && find . -maxdepth 4 -name package.json -not -path '*/node_modules/*' -not -path './.git/*' -print0 | sort -z)
}
ensure_workspace_builds() {
  local wt="$1" todo pass d left
  [ "${WT_DEPS_BUILD_WORKSPACES:-1}" = 0 ] && return 0
  todo="$(missing_workspace_builds "$wt" | sed 's#^\./##' | sort -u)"
  [ -n "$todo" ] || return 0
  # packages may depend on each other's output: retry the failures once after the others built
  for pass in 1 2; do
    left=""
    while IFS= read -r d; do
      [ -n "$d" ] || continue
      log "building workspace output of $d in $wt"
      (cd "$wt/$d" && npm run build >&2) || left="$left$d"$'\n'
    done <<< "$todo"
    todo="$(printf '%s' "$left" | sed '/^$/d')"; [ -n "$todo" ] || return 0
  done
  log "WARN: workspace build failed for: $(echo $todo)"; return 1
}
ensure_outputs() { ensure_prisma_client "$1"; local rc=$?; ensure_workspace_builds "$1" || rc=1; return $rc; }

# hook mode: trust gate (see header). One validator shared with the git hook dispatcher and install.sh.
IGN=""
if [ "${WT_DEPS_HOOK:-0}" = 1 ] && [ "$CHECK" = 0 ]; then
  . "$(dirname "${BASH_SOURCE[0]}")/lib/trusted-origin.sh" 2>/dev/null || { log "hook mode: trusted-origin lib missing - NOT installing"; exit 0; }
  if ! wt_trusted_repo "$WT"; then
    log "hook mode: $WT is not a trusted repo (origin '$(git -C "$WT" config --get remote.origin.url 2>/dev/null)') - NOT installing deps automatically"; exit 0
  fi
  IGN=1   # hook mode is CLONE-ONLY: see the cache-miss rule below; no installer ever runs from a hook
fi

[ -n "$IGN" ] && WT_DEPS_REFRESH=0
REFRESH="${WT_DEPS_REFRESH:-0}"

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
  log "falling back to a normal install in $WT"; (cd "$WT" && "${INSTALL[@]}") || return $?
  # no cache here (non-APFS, lock timeout, clone failure), but the worktree still must end with a real client + built outputs
  ensure_outputs "$WT" || true; }

# already installed here? (leave a real install alone unless forced)
if [ -d "$WT/node_modules" ] && [ -n "$(ls -A "$WT/node_modules" 2>/dev/null)" ] && [ "${WT_DEPS_FORCE:-0}" != 1 ] && [ "$REFRESH" != 1 ]; then
  # a populated node_modules is left alone, but a missing/stub prisma client is still repaired (hook mode never generates)
  [ -z "$IGN" ] && ensure_outputs "$WT"
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
if [ ! -f "$ENTRY/.complete" ] || [ "$REFRESH" = 1 ]; then
  # one builder per key; others wait (stale lock after 20 min is broken)
  waited=0
  until mkdir "$lock_dir" 2>/dev/null; do
    [ -f "$ENTRY/.complete" ] && [ "$REFRESH" != 1 ] && break
    if [ -n "$(find "$lock_dir" -maxdepth 0 -mmin +20 2>/dev/null)" ]; then rmdir "$lock_dir" 2>/dev/null; continue; fi
    sleep 3; waited=$((waited+3)); [ "$waited" -gt 1500 ] && { log "lock wait timeout"; plain_install; exit $?; }
  done
  if [ ! -f "$ENTRY/.complete" ] || [ "$REFRESH" = 1 ]; then
    trap 'rmdir "$lock_dir" 2>/dev/null' EXIT
    log "cache MISS $REPO/$KEY - installing once in $WT"
    rm -rf "${WT:?}/node_modules"
    if ! (cd "$WT" && "${INSTALL[@]}"); then log "install failed"; exit 1; fi
    ensure_prisma_client "$WT" || { log "prisma generate failed - not caching a stub client"; exit 1; }
    ensure_workspace_builds "$WT" || true
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
  if [ -z "$IGN" ]; then ensure_outputs "$WT" || true
  elif [ -n "$(missing_workspace_builds "$WT")" ]; then
    log "hook mode: workspace build outputs are missing in $WT (never built from a hook) - run by hand: bash ~/.claude/scripts/wt-deps.sh $WT"
  fi
  if [ -n "$IGN" ] && has_prisma_schema "$WT" && ! prisma_client_ok "$WT"; then
    log "hook mode: prisma client in $WT is a stub - run by hand: bash ~/.claude/scripts/wt-deps.sh $WT (or WT_DEPS_REFRESH=1 to rebuild the cache entry)"
  fi
  # husky's `prepare` never ran in a clone, so its (gitignored) .husky/_ stubs are missing and the repo's
  # git hooks (pre-commit/commit-msg/pre-push) would silently not fire in this worktree. Re-run husky (offline, instant).
  # NOT in hook mode: it would execute dependency code (that is what --ignore-scripts exists to prevent).
  if [ -z "$IGN" ] && [ -x "$WT/node_modules/.bin/husky" ] && grep -q '"husky' "$WT/package.json" 2>/dev/null && [ ! -d "$WT/.husky/_" ]; then
    (cd "$WT" && node_modules/.bin/husky >/dev/null 2>&1) && log "husky hooks re-armed in $WT" || log "WARN: husky re-arm failed in $WT"
  fi
  exit 0
fi
log "clone failed"; plain_install
