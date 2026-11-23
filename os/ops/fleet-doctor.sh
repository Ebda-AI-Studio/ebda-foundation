#!/usr/bin/env bash
# Ebda AI OS - fleet-doctor.sh (register OS-F1): one verdict per subject, each with its evidence.
#
#   fleet-doctor.sh [--repo OWNER/NAME]... [--dir CHECKOUT]... [--no-notify] [--quiet]
#
# CI runs on GitHub-hosted ubuntu-24.04 (repo vars EBDA_*RUNS_ON); the Mac runners are not the CI, so their being offline is
# a finding ONLY for a repo whose variable is unset (its workflows then fall back to the Mac label and would queue forever).
# Per repo:   ci-target     EBDA_RUNS_ON set (hosted/self-hosted) - FAIL when unset and no self-hosted runner is online
#             queue         capacity.sh verdict (SATURATED/STARVED = FAIL, UNKNOWN = UNKNOWN)
#             main-protect  a ruleset named `main-protection` exists (per repo: the org is on Free, no org rulesets)
#             conflicts     open PRs that conflict with main and carry no `rebase-needed` label (the merge train is not covering them)
# Per checkout (--dir / DOCTOR_DIRS):  git-config  `core.bare` must not be true (a hook-exported GIT_DIR once set it on a shared repo)
# Host:       ops-drift     installed ~/.claude/scripts hooks + top-level scripts equal this repo's os/ops (merged != installed)
#             clock         local clock within 120 s of GitHub's `Date` header (a skewed clock breaks token and cron checks)
# Verdicts: OK | FAIL | UNKNOWN (a read failed: never reported as OK). One TSV line each: subject<TAB>verdict<TAB>evidence.
# Exit: 0 all OK, 1 any FAIL, 2 UNKNOWN and no FAIL. FAILs are announced once per distinct set via notify.sh (--no-notify skips).
# Writes $OS_STATE_DIR/fleet-doctor/last.tsv. Test seams: `gh`, `curl`, `git` from PATH; OS_STATE_DIR; FLEET_REPOS; DOCTOR_DIRS;
# DOCTOR_INSTALLED (default ~/.claude/scripts); FLEET_DOCTOR_NOTIFY.
# shellcheck source=lib/os-config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/os-config.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-config.sh" 2>/dev/null || true
command -v os_config_load >/dev/null 2>&1 && os_config_load
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/args.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/args.sh" 2>/dev/null || true
. "$HERE/lib/os-state.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-state.sh" 2>/dev/null || true
command -v _ut >/dev/null 2>&1 || _ut() { shift; "$@"; }
command -v args_help >/dev/null 2>&1 && args_help "$0" "$@"
GH_TIMEOUT="${GH_TIMEOUT:-45}"
repos=(); dirs=(); notify=1; quiet=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repos+=("${2:?--repo needs OWNER/NAME}"); shift 2 ;;
    --dir) dirs+=("${2:?--dir needs a path}"); shift 2 ;;
    --no-notify) notify=0; shift ;;
    --quiet) quiet=1; shift ;;
    *) echo "fleet-doctor.sh: unknown argument '$1' (try --help)" >&2; exit 2 ;;
  esac
done
# shellcheck disable=SC2206
[ "${#repos[@]}" -gt 0 ] || repos=(${FLEET_REPOS:-${OS_REPO_SLUG:-}})
# shellcheck disable=SC2206
[ "${#dirs[@]}" -gt 0 ] || dirs=(${DOCTOR_DIRS:-})
ghx() { _ut "$GH_TIMEOUT" gh "$@"; }
rows=""; nfail=0; nunk=0
verdict() { # subject verdict evidence
  rows="$rows$1	$2	$3
"
  case "$2" in FAIL) nfail=$((nfail+1)) ;; UNKNOWN) nunk=$((nunk+1)) ;; esac
}

for repo in ${repos[@]+"${repos[@]}"}; do
  # ci-target
  rn="?"
  if rj="$(ghx api "repos/$repo/actions/runners" 2>/dev/null)"; then
    rn="$(printf '%s' "$rj" | python3 -I -c 'import sys,json
try:
    print(len([x for x in json.load(sys.stdin).get("runners",[]) if x.get("status")=="online"]))
except Exception:
    print("?")')"
  fi
  if v="$(ghx api "repos/$repo/actions/variables/EBDA_RUNS_ON" --jq .value 2>/dev/null)"; then
    verdict "$repo ci-target" OK "EBDA_RUNS_ON=$v self-hosted-online=$rn"
  elif [ "$rn" = "?" ]; then
    verdict "$repo ci-target" UNKNOWN "EBDA_RUNS_ON unreadable and runners unreadable"
  elif [ "$rn" -gt 0 ] 2>/dev/null; then
    verdict "$repo ci-target" OK "EBDA_RUNS_ON unset, $rn self-hosted runner(s) online (Mac label)"
  else
    verdict "$repo ci-target" FAIL "EBDA_RUNS_ON unset and 0 self-hosted runners online: jobs fall back to the Mac label and queue forever"
  fi
  # queue
  qline="$(OS_STATE_DIR="${OS_STATE_DIR:-$HOME/.whisky-os-state}" bash "$HERE/capacity.sh" --repo "$repo" 2>/dev/null | head -1)"
  qv="$(printf '%s' "$qline" | cut -f2)"
  case "$qv" in
    OK|BUSY) verdict "$repo queue" OK "$(printf '%s' "$qline" | cut -f2-)" ;;
    SATURATED|STARVED) verdict "$repo queue" FAIL "$(printf '%s' "$qline" | cut -f2-)" ;;
    *) verdict "$repo queue" UNKNOWN "capacity.sh gave no verdict" ;;
  esac
  # main-protection ruleset
  if rs="$(ghx api "repos/$repo/rulesets" --jq '.[].name' 2>/dev/null)"; then
    if printf '%s\n' "$rs" | grep -qx 'main-protection'; then verdict "$repo main-protect" OK "ruleset main-protection present"
    else verdict "$repo main-protect" FAIL "no ruleset named main-protection (rulesets: $(printf '%s' "$rs" | tr '\n' ',' ))"; fi
  else verdict "$repo main-protect" UNKNOWN "rulesets unreadable (permissions or plan)"; fi
  # conflicts not covered by the train
  if pj="$(ghx pr list --repo "$repo" --state open --limit 100 --json number,mergeable,labels 2>/dev/null)"; then
    unc="$(printf '%s' "$pj" | python3 -I -c 'import sys,json
try:
    prs=json.load(sys.stdin)
except Exception:
    print("?"); sys.exit(0)
print(",".join("#%s" % p["number"] for p in prs if p.get("mergeable")=="CONFLICTING" and "rebase-needed" not in [l.get("name") for l in p.get("labels",[])]))')"
    case "$unc" in
      "") verdict "$repo conflicts" OK "no uncovered conflicting PR" ;;
      "?") verdict "$repo conflicts" UNKNOWN "PR list unparseable" ;;
      *) verdict "$repo conflicts" FAIL "conflicting without rebase-needed: $unc" ;;
    esac
  else verdict "$repo conflicts" UNKNOWN "PR list unreadable"; fi
done

for d in ${dirs[@]+"${dirs[@]}"}; do
  if [ ! -d "$d" ]; then verdict "git-config $d" UNKNOWN "not a directory"; continue; fi
  if ! git -C "$d" rev-parse --git-dir >/dev/null 2>&1; then verdict "git-config $d" UNKNOWN "not a git checkout"; continue; fi
  if bare="$(git -C "$d" config --get core.bare 2>/dev/null)" || [ -z "$bare" ]; then
    if [ "$bare" = true ]; then verdict "git-config $d" FAIL "core.bare=true on a working checkout (a hook-exported GIT_DIR did this once)"
    else verdict "git-config $d" OK "core.bare=${bare:-unset} hooksPath=$(git -C "$d" config --get core.hooksPath 2>/dev/null || echo unset)"; fi
  else verdict "git-config $d" UNKNOWN "git config unreadable"; fi
done

# ops-drift: only meaningful where the OS is installed (a Mac); elsewhere UNKNOWN with the reason, never OK
inst="${DOCTOR_INSTALLED:-$HOME/.claude/scripts}"; src="$(cd "$HERE" && pwd)"
if [ ! -d "$inst" ] || [ "$(cd "$inst" 2>/dev/null && pwd)" = "$src" ]; then
  verdict "ops-drift" UNKNOWN "no separate installed copy at $inst (not installed here)"
else
  drift=""
  for f in "$src"/*.sh "$src"/hooks/*.sh; do
    rel="${f#"$src"/}"
    if [ ! -e "$inst/$rel" ]; then drift="$drift $rel(missing)"; elif ! cmp -s "$f" "$inst/$rel"; then drift="$drift $rel(differs)"; fi
  done
  if [ -z "$drift" ]; then verdict "ops-drift" OK "installed copy equals os/ops"
  else verdict "ops-drift" FAIL "merged != installed:$drift (run os/install.sh)"; fi
fi

# clock: GitHub's Date header vs the local clock
if hdr="$(_ut 15 curl -sI --max-time 10 https://api.github.com 2>/dev/null)" && skew="$(printf '%s' "$hdr" | python3 -I -c 'import sys,time,email.utils
for l in sys.stdin:
    if l.lower().startswith("date:"):
        t=email.utils.parsedate_to_datetime(l.split(":",1)[1].strip()).timestamp()
        print(int(abs(time.time()-t))); sys.exit(0)
sys.exit(1)' 2>/dev/null)"; then
  if [ "$skew" -le 120 ]; then verdict "clock" OK "skew ${skew}s vs api.github.com"; else verdict "clock" FAIL "skew ${skew}s vs api.github.com (> 120)"; fi
else verdict "clock" UNKNOWN "no Date header from api.github.com"; fi

sd="${OS_STATE_DIR:-$HOME/.whisky-os-state}/fleet-doctor"
if mkdir -p "$sd" 2>/dev/null; then
  printf '%s' "$rows" > "$sd/last.tsv.tmp" && mv "$sd/last.tsv.tmp" "$sd/last.tsv"
  if [ "$nfail" -gt 0 ] && [ "$notify" -eq 1 ]; then
    fails="$(printf '%s' "$rows" | awk -F'\t' '$2=="FAIL"')"
    key="$(printf '%s' "$fails" | cksum | cut -d' ' -f1)"
    if [ "$(cat "$sd/notified.key" 2>/dev/null)" != "$key" ]; then
      echo "$key" > "$sd/notified.key"
      "${FLEET_DOCTOR_NOTIFY:-$HERE/notify.sh}" "fleet-doctor: $nfail FAIL" "$fails" >/dev/null 2>&1 || true
    fi
  elif [ "$nfail" -eq 0 ]; then rm -f "$sd/notified.key"; fi
fi
[ "$quiet" -eq 1 ] || printf '%s' "$rows"
if [ "$nfail" -gt 0 ]; then exit 1; elif [ "$nunk" -gt 0 ]; then exit 2; fi
exit 0
