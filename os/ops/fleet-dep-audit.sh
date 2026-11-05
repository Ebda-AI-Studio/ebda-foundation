#!/usr/bin/env bash
# fleet-dep-audit.sh — closes gap G8 (2026-07-22 audit). Dependency vulns were
# caught only reactively, per-PR, when a repo's zero-vuln CI gate happened to run
# — so one transitive advisory (brace-expansion GHSA-3jxr) sat red across BOTH
# ebda-studio and digital-card at once with no proactive signal. This sweeps
# every local Force AI repo weekly, runs `npm audit`, and alerts with the exact
# advisories + fix, so a fleet-wide advisory is seen and fixed before it blocks
# delivery. Detect+alert by default; set FLEET_AUDIT_AUTOPR=1 to also open fix
# PRs (off by default — a cron must not silently spam PRs across the fleet).
# shellcheck source=lib/os-config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/os-config.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-config.sh" 2>/dev/null || true
command -v os_config_load >/dev/null 2>&1 && os_config_load
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/bin:/bin:$PATH"
HERE="${FLEET_AUDIT_HERE:-$HOME/.claude/scripts}"
STATE="$HOME/.whisky-os-state"; LOG="$STATE/fleet-dep-audit.log"; mkdir -p "$STATE"
NOTIFY="${FLEET_AUDIT_NOTIFY:-$HERE/notify.sh}"
ts(){ date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo now; }
. "$HERE/lib/os-state.sh" 2>/dev/null || true

PROJ_ROOT="${FLEET_AUDIT_ROOT:-$OS_PROJECTS_DIR}"
NPM_BIN="${FLEET_AUDIT_NPM:-npm}"; PNPM_BIN="${FLEET_AUDIT_PNPM:-pnpm}"
# audit level mirrors the fleet CI gate (prod-deps zero-tolerance). Override via env.
LEVEL="${FLEET_AUDIT_LEVEL:-high}"

# Names never descended into: deps, build output, and the non-slot meta folders
# (worktrees are duplicates of a root checkout; backups/archive are not the fleet).
PRUNE=( -name node_modules -o -name _worktrees -o -name _backups -o -name _archive \
        -o -name _reorg -o -name build -o -name dist -o -name .next -o -name .open-next )

# Discover git repo ROOTS at ANY depth under PROJ_ROOT. A `.git` DIRECTORY marks a
# real checkout (a worktree's `.git` is a FILE, so -type d skips it). The old
# `find -maxdepth 3 -name package.json` went blind when the 2026-09-25 business-folder
# layout put repos 3-5 levels deep, and would have printed "OK — 0 repos".
# -print0 + read -d '' keeps paths with spaces whole. bash 3.2: no mapfile.
REPOS=()
while IFS= read -r -d '' g; do
  d="${g%/.git}"; nested=0
  for k in ${REPOS[@]+"${REPOS[@]}"}; do
    case "$d/" in "$k/"*) nested=1; break;; esac    # vendored checkout inside a repo
  done
  [ "$nested" = 1 ] || REPOS+=("$d")
done < <(find "$PROJ_ROOT" -maxdepth 8 \( "${PRUNE[@]}" \) -prune -o -name .git -type d -print0 2>/dev/null | sort -z)

# Lockfiles per repo: every package-lock.json / pnpm-lock.yaml, including sub-dir
# ones (ebda-whatsapp/backend, /frontend). Audit reads the lockfile; never installs.
# A sub-directory that is itself a git checkout (vendored) is pruned: not ours to audit.
LOCKS=()
for d in ${REPOS[@]+"${REPOS[@]}"}; do
  while IFS= read -r -d '' lf; do LOCKS+=("$lf"); done < <(
    find "$d" -mindepth 1 -maxdepth 5 \( "${PRUNE[@]}" -o -name .git \) -prune -o \
      -type d -exec test -e '{}/.git' ';' -prune -o \
      \( -name package-lock.json -o -name pnpm-lock.yaml \) -type f -print0 2>/dev/null | sort -z)
done
n_repos=${#REPOS[@]}; n_locks=${#LOCKS[@]}

# A sweep that audited nothing must never read as clean.
fail_run() {
  local msg="$1"
  echo "fleet-dep-audit: FAILED — $msg" >&2
  printf '%s [fleet-dep-audit] FAILED %s\n' "$(ts)" "$msg" >>"$LOG"
  command -v write_status >/dev/null 2>&1 && write_status "fleet-dep-audit" "false" "FAILED — $msg" "{\"repos\":$n_repos,\"lockfiles\":$n_locks}"
  [ -x "$NOTIFY" ] && "$NOTIFY" "📦 Fleet dep-audit FAILED" "$msg (root: $PROJ_ROOT)" >/dev/null 2>&1 || true
  exit 1
}
[ "$n_repos" -gt 0 ] || fail_run "discovered 0 git repos under $PROJ_ROOT (layout moved again?)"
[ "$n_locks" -gt 0 ] || fail_run "discovered $n_repos repos but 0 lockfiles"

# Summarise one audit JSON (npm `vulnerabilities` map OR pnpm `advisories` map).
# stdout: nothing = clean; "!ERR\t<why>" = audit did not run; else "slug\tcounts\thits".
summarise() {
  LEVEL="$LEVEL" SLUG="$1" python3 -c "
import json,sys,os
order={'info':0,'low':1,'moderate':2,'high':3,'critical':4}
minr=order.get(os.environ['LEVEL'],3)
try: d=json.load(sys.stdin)
except Exception: print('!ERR\tunparseable audit output'); sys.exit()
if not isinstance(d,dict) or d.get('error'):
    e=d.get('error') if isinstance(d,dict) else None
    print('!ERR\t%s' % ((e.get('summary') or e.get('code') or 'audit error') if isinstance(e,dict) else (e or 'unexpected output'))); sys.exit()
md=(d.get('metadata') or {}).get('vulnerabilities') or {}
hits=[]
for name,v in (d.get('vulnerabilities') or {}).items():
    sev=v.get('severity','')
    if order.get(sev,0) < minr: continue
    ga=''
    for x in (v.get('via') or []):
        if isinstance(x,dict): ga=x.get('url','') or x.get('source',''); break
    hits.append('%s (%s) %s' % (name, sev, ga))
adv=d.get('advisories') or {}
for v in (adv.values() if isinstance(adv,dict) else adv):
    sev=v.get('severity','')
    if order.get(sev,0) < minr: continue
    hits.append('%s (%s) %s' % (v.get('module_name',''), sev, v.get('url','')))
counts=' '.join('%s:%d'%(k,md.get(k,0)) for k in ('critical','high','moderate','low') if md.get(k,0))
if hits: print('%s\t%s\t%s' % (os.environ['SLUG'], counts, ' | '.join(hits[:6])))
" 2>/dev/null
}

n_vuln=0; n_err=0; report=""; errs=""
for lf in ${LOCKS[@]+"${LOCKS[@]}"}; do
  dir=$(dirname "$lf")
  # slug = repo basename + sub-dir inside the repo (ebda-whatsapp/backend)
  repo=""; for r in ${REPOS[@]+"${REPOS[@]}"}; do case "$dir/" in "$r/"*) repo="$r"; break;; esac; done
  slug=$(basename "$repo"); rel="${dir#"$repo"}"; slug="$slug${rel:+${rel}}"
  case "$lf" in
    */pnpm-lock.yaml) aj=$(cd "$dir" && "$PNPM_BIN" audit --prod --json 2>/dev/null); slug="$slug (pnpm)";;
    *)                aj=$(cd "$dir" && "$NPM_BIN" audit --omit=dev --json 2>/dev/null);;
  esac
  summary=$(printf '%s' "$aj" | summarise "$slug")
  case "$summary" in
    "!ERR"*) n_err=$((n_err+1)); errs="$errs  • $slug: ${summary#*$'\t'}"$'\n';;
    "") ;;
    *) n_vuln=$((n_vuln+1)); report="$report$summary"$'\n';;
  esac
done

printf '%s [fleet-dep-audit] scanned %s repos, %s lockfiles, %s with >=%s vulns, %s audit errors\n' "$(ts)" "$n_repos" "$n_locks" "$n_vuln" "$LEVEL" "$n_err" >>"$LOG"
# every lockfile failing to audit (registry down, tool missing) is a failed sweep, not a clean one
[ "$n_err" -lt "$n_locks" ] || fail_run "all $n_locks lockfile audits errored: $(printf '%s' "$errs" | head -2 | tr '\n' ' ')"
if [ "$n_vuln" -eq 0 ] && [ "$n_err" -eq 0 ]; then
  echo "fleet-dep-audit: OK — $n_repos repos, $n_locks lockfiles, none with >=$LEVEL prod-dep vulns."
  command -v write_status >/dev/null 2>&1 && write_status "fleet-dep-audit" "true" "clean — $n_repos repos, $n_locks lockfiles, 0 with >=$LEVEL vulns" "{\"repos\":$n_repos,\"lockfiles\":$n_locks}"
  exit 0
fi

pretty=$(printf '%s' "$report" | awk -F'\t' 'NF{printf "  • %s [%s]\n      %s\n",$1,$2,$3}')
echo "fleet-dep-audit: $n_vuln/$n_locks lockfile(s) across $n_repos repos with >=$LEVEL prod-dep vuln(s):"
printf '%s\n' "$pretty"
[ "$n_err" -gt 0 ] && { echo "AUDIT ERRORS ($n_err lockfiles not audited):"; printf '%s' "$errs"; }
# cross-repo advisory correlation: same advisory in multiple repos = fleet-wide
fleet=$(printf '%s' "$report" | awk -F'\t' '{print $3}' | tr '|' '\n' | grep -oE 'GHSA-[a-z0-9-]+' | sort | uniq -c | awk '$1>1{print "  ‼ "$2" affects "$1" lockfiles"}')
[ -n "$fleet" ] && { echo "FLEET-WIDE advisories:"; printf '%s\n' "$fleet"; }
printf '%s [fleet-dep-audit] %s lockfiles vuln, %s errors\n' "$(ts)" "$n_vuln" "$n_err" >>"$LOG"
unaud=""; [ "$n_err" -gt 0 ] && unaud=", $n_err unaudited"
# vuln_repos keeps its name for status consumers; it now counts vulnerable lockfiles.
command -v write_status >/dev/null 2>&1 && write_status "fleet-dep-audit" "warn" "$n_vuln/$n_locks lockfiles ($n_repos repos) have >=$LEVEL prod-dep vulns$unaud" "{\"vuln_repos\":$n_vuln,\"repos\":$n_repos,\"lockfiles\":$n_locks,\"errors\":$n_err}"
[ -x "$NOTIFY" ] && "$NOTIFY" "📦 Fleet dep-audit: $n_vuln lockfile(s) with >=$LEVEL vulns" \
  "$pretty"$'\n'"${errs:+Not audited:
$errs}${fleet:+FLEET-WIDE:
$fleet
}Fix: in each repo add a leaf override to the patched version (verify with npm view <pkg>@<v>), refresh the lockfile, PR. Same advisory across repos = fix once, propagate." >/dev/null 2>&1 || true
exit 0
