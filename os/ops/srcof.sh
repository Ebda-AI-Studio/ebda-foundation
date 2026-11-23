#!/usr/bin/env bash
# srcof — print the path to the EXACT source of a published package version.
#
# Why this exists: `opensrc path` resolves tags as v<version> only. Packages
# published from a monorepo tag as "<pkg>@<version>", so opensrc misses the tag,
# silently clones the DEFAULT BRANCH, and caches it under a directory named with
# the version you asked for. `opensrc path` then prints that path with no warning
# and exit 0 — you get a different version's source labelled as yours.
# Measured 2026-08-16: @opennextjs/cloudflare@1.19.11 -> 1.20.2,
# @upstash/redis@1.34.0 -> 1.30.2, @radix-ui/react-dialog@1.1.1 -> 0.1.0.
#
# srcof resolves a ref with PROVENANCE (published commit, or a tag proven to
# exist upstream) and exits non-zero if it cannot. It never guesses.
#
#   srcof @opennextjs/cloudflare@1.19.11
#   srcof @prisma/client --cwd $OS_PROJECTS_DIR/$OS_ORG/internal-projects/ebda-store/apps/api
#   rg "getCloudflareContext" "$(srcof @opennextjs/cloudflare@1.19.11)"
# shellcheck source=lib/os-config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/os-config.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-config.sh" 2>/dev/null || true
command -v os_config_load >/dev/null 2>&1 && os_config_load
set -euo pipefail

CACHE="${SRCOF_CACHE:-$HOME/.srcof}"

die()  { printf 'srcof: %s\n' "$*" >&2; exit 1; }
note() { printf 'srcof: %s\n' "$*" >&2; }

spec="${1:-}"
[ -n "$spec" ] || die "usage: srcof <pkg>[@version] [--cwd DIR]"
shift || true

cwd="$PWD"
while [ $# -gt 0 ]; do
  case "$1" in
    --cwd) cwd="${2:?--cwd needs a directory}"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

# Split name@version. Leading @ is a scope, not a version separator.
base="${spec#@}"
if [[ "$base" == *@* ]]; then
  name="${spec%@*}"; ver="${spec##*@}"
else
  name="$spec"; ver=""
fi

# Resolve the version from what is actually installed, then the registry.
if [ -z "$ver" ]; then
  installed="$cwd/node_modules/$name/package.json"
  if [ -f "$installed" ]; then
    ver=$(node -p "require('$installed').version")
    note "version from $cwd/node_modules: $ver"
  else
    ver=$(npm view "$name" version 2>/dev/null) || die "cannot resolve a version for $name"
    note "version from registry (latest): $ver — not necessarily what you run"
  fi
fi

dest="$CACHE/$name/$ver"
if [ -f "$dest/.srcof-ref" ]; then
  printf '%s\n' "$(cat "$dest/.srcof-pkgdir")"
  exit 0
fi

repo=$(npm view "$name@$ver" repository.url 2>/dev/null | sed -e 's|^git+||' -e 's|^git://|https://|' -e 's|\.git$||')
[ -n "$repo" ] || die "$name@$ver declares no repository — no source to fetch"

# Ladder, most authoritative first. Each rung must be PROVEN against the remote.
ref=""; how=""
head=$(npm view "$name@$ver" gitHead 2>/dev/null || true)
if [ -n "$head" ]; then
  ref="$head"; how="npm gitHead (exact published commit)"
else
  for cand in "$name@$ver" "v$ver" "$ver" "$(basename "$name")@$ver" "$(basename "$name")-v$ver"; do
    if grep -q . < <(git ls-remote --tags "$repo" "refs/tags/$cand" 2>/dev/null); then
      ref="$cand"; how="tag $cand (verified present upstream)"; break
    fi
  done
fi
[ -n "$ref" ] || die "no provable ref for $name@$ver in $repo — refusing to guess (opensrc would clone the default branch here)"

note "fetching $name@$ver via $how"
rm -rf "$dest"; mkdir -p "$dest"
(
  cd "$dest"
  git init -q
  git remote add origin "$repo"
  git fetch -q --depth 1 origin "$ref" 2>/dev/null || die "fetch of $ref failed"
  git checkout -q FETCH_HEAD
)

# In a monorepo the package lives in a subdirectory; find the one that declares this name.
pkgdir=$(node -e '
const fs=require("fs"),path=require("path");
const root=process.argv[1],want=process.argv[2];
const skip=new Set(["node_modules",".git","test","tests","fixtures","examples","e2e"]);
let hit="";
(function walk(d,depth){
  if(hit||depth>4) return;
  let ents; try{ents=fs.readdirSync(d,{withFileTypes:true})}catch{return}
  const pj=path.join(d,"package.json");
  if(fs.existsSync(pj)){
    try{ if(JSON.parse(fs.readFileSync(pj,"utf8")).name===want){ hit=d; return } }catch{}
  }
  for(const e of ents) if(e.isDirectory()&&!skip.has(e.name)&&!e.name.startsWith(".")) walk(path.join(d,e.name),depth+1);
})(root,0);
process.stdout.write(hit||root);
' "$dest" "$name")

printf '%s' "$ref" > "$dest/.srcof-ref"
printf '%s' "$pkgdir" > "$dest/.srcof-pkgdir"
printf '%s\n' "$pkgdir"
