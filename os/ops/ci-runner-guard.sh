#!/usr/bin/env bash
# Ebda AI OS — CI runner guard.
#
# CI runs ONLY on native macOS GitHub runners (Umbra, the old local Linux VM, was
# retired 2026-11-14: Ruling UMBRA-RETIRE-1). Fleet health is therefore judged from
# the GitHub API alone: `gh api orgs/<org>/actions/runners` -> which runners are
# online / busy, grouped by label. Nothing here starts, stops or rebuilds a machine;
# the runners are launchd services (actions.runner.<org>.<name>) on the Mac and the
# guard only REPORTS, so a human (or runner-restore.sh's caller) acts on the finding.
#
# Per org in $RUNNER_ORGS (default: the primary org, $OS_ORG):
#   - org has no runners registered at all  -> note (nothing to guard)
#   - EVERY runner of the org is offline     -> finding (CI queues forever)
#   - EVERY runner carrying one label offline (e.g. all `ebda-mac` heavy runners
#     while the `ebda-mac-light` ones are up) -> finding
#   - some runners offline / all busy        -> note only (busy is normal under load)
# Plus the host disk: a full Mac disk wedges runner jobs (read-only, no mutation).
#
# Exit 0 = nothing to act on, 1 = at least one finding (also announced via notify.sh).
# Test seams: `gh` is resolved from PATH, HOST_DISK_*_PCT, RUNNER_ORGS, HOME.
# shellcheck source=lib/os-config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/os-config.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-config.sh" 2>/dev/null || true
command -v os_config_load >/dev/null 2>&1 && os_config_load
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/os-state.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-state.sh" 2>/dev/null || true
. "$HERE/lib/disk-pressure.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/disk-pressure.sh" 2>/dev/null || true
# A monitor that can block forever on what it monitors goes quiet, and quiet reads as
# healthy (2026-08-03: a wedged probe silenced this guard for 4h). Every gh call is
# wall-clocked through _ut; without the lib we run unbounded rather than not at all.
command -v _ut >/dev/null 2>&1 || _ut() { shift; "$@"; }
GH_TIMEOUT="${GH_TIMEOUT:-45}"

findings=()   # fleet states that need a human
notes=()      # informational status
flipped() { findings+=("$1"); }
note()    { notes+=("$1"); }

RUNNER_ORGS="${RUNNER_ORGS:-${OS_ORG:-}}"
[ -n "$RUNNER_ORGS" ] || flipped "no org to check: OS_ORG is empty (os-config.sh / os.env not loaded) and RUNNER_ORGS is unset — the guard would otherwise report a fleet it never looked at as healthy"

# fleet_summary <json> — one line per label group plus an org line, TAB separated:
#   org<TAB>total<TAB>online<TAB>busy<TAB>offline-names
#   label<TAB><name><TAB>total<TAB>online
# Empty/invalid JSON prints nothing and returns 1 (UNKNOWN, never "all offline").
fleet_summary() {
  python3 -c '
import sys, json
try:
    runners = json.load(sys.stdin).get("runners", [])
except Exception:
    sys.exit(1)
on = [r for r in runners if r.get("status") == "online"]
off = [r["name"] for r in runners if r.get("status") != "online"]
busy = [r for r in on if r.get("busy")]
print("org\t%d\t%d\t%d\t%s" % (len(runners), len(on), len(busy), ",".join(off)))
labels = {}
for r in runners:
    for l in r.get("labels", []):
        n = l.get("name", "")
        if n in ("self-hosted", "macOS", "ARM64", "X64", "Linux", ""):
            continue   # generic labels: every runner has them, they say nothing about a pool
        t = labels.setdefault(n, [0, 0]); t[0] += 1; t[1] += 1 if r.get("status") == "online" else 0
for n, (t, o) in sorted(labels.items()):
    print("label\t%s\t%d\t%d" % (n, t, o))
' 2>/dev/null
}

for org in $RUNNER_ORGS; do
  json="$(_ut "$GH_TIMEOUT" gh api "orgs/$org/actions/runners?per_page=100" 2>/dev/null)"
  if ! sum="$(printf '%s' "$json" | fleet_summary)" || [ -z "$sum" ]; then
    # Unknown is not healthy and not "all offline": say so, do not page a guess.
    note "$org: runner list unreadable (gh api orgs/$org/actions/runners failed or needs the admin:org scope) — fleet NOT evaluated this cycle"
    continue
  fi
  IFS=$'\t' read -r _ total online busy offnames < <(printf '%s\n' "$sum" | grep '^org')
  if [ "${total:-0}" -eq 0 ]; then
    note "$org: no self-hosted runners registered at org level — nothing to guard"
    continue
  fi
  if [ "$online" -eq 0 ]; then
    flipped "$org: ALL $total runner(s) OFFLINE (${offnames}) — CI jobs routed to them will queue forever. Check the launchd services on the Mac: launchctl list | grep actions.runner.$org ; restart one with: launchctl kickstart -k gui/\$(id -u)/actions.runner.$org.<name>"
  else
    note "$org: ${online}/${total} runners online, ${busy} busy${offnames:+; offline: $offnames}"
    while IFS=$'\t' read -r _ lbl lt lo; do
      [ -n "$lbl" ] || continue
      if [ "$lo" -eq 0 ]; then
        flipped "$org: every runner with label '$lbl' ($lt) is OFFLINE while others are up — workflows with runs-on '$lbl' will queue forever. Restart the actions.runner.$org.* launchd service(s) for that pool."
      fi
    done < <(printf '%s\n' "$sum" | grep '^label')
  fi
done

# ── host disk (a full Mac disk fails runner jobs; read-only check) ───────────
HOST_DISK_WARN_PCT=${HOST_DISK_WARN_PCT:-88}
HOST_DISK_CRIT_PCT=${HOST_DISK_CRIT_PCT:-94}
HOST_VOL="/System/Volumes/Data"; [ -d "$HOST_VOL" ] || HOST_VOL="/"
host_disk_used=$(host_disk_used_pct "$HOST_VOL" 2>/dev/null)
host_disk_free_g=$(host_disk_free_gb "$HOST_VOL" 2>/dev/null)
# Unreadable is UNKNOWN, never ok.
case "$(disk_pressure_level "$host_disk_used" "$HOST_DISK_WARN_PCT" "$HOST_DISK_CRIT_PCT" 2>/dev/null)" in
  crit)    flipped "HOST disk ${host_disk_used}% used, only ${host_disk_free_g:-?}GB free (>=${HOST_DISK_CRIT_PCT}%) — runner jobs fail and the Mac degrades. Free space (worktrees, Xcode DerivedData, npm cache, ~/.cache)." ;;
  warn)    note "host disk: ${host_disk_used}% used, ${host_disk_free_g:-?}GB free (warn >=${HOST_DISK_WARN_PCT}%) — reclaim before it reaches ${HOST_DISK_CRIT_PCT}%" ;;
  unknown) note "host disk: unreadable (df on $HOST_VOL returned nothing)" ;;
  *)       note "host disk: ${host_disk_used}% used, ${host_disk_free_g:-?}GB free — ok" ;;
esac

# ── report ────────────────────────────────────────────────────────────────────
if [ ${#findings[@]} -eq 0 ]; then
  echo "[ci-runner-guard] OK — no action needed."
  [ ${#notes[@]} -gt 0 ] && printf '  %s\n' ${notes[@]+"${notes[@]}"}
  write_status "runner" "true" "no action needed — all runners healthy" '{}'
  exit 0
fi
msg="CI Runner Guard — ${#findings[@]} action(s):"$'\n'"$(printf '  • %s\n' ${findings[@]+"${findings[@]}"})"
[ ${#notes[@]} -gt 0 ] && msg="$msg"$'\n'"$(printf '  · %s\n' ${notes[@]+"${notes[@]}"})"
echo "$msg"
"$HERE/notify.sh" "CI Runner Guard" "$msg" >/dev/null 2>&1 || true
DETAIL=$(printf '%s\n' ${findings[@]+"${findings[@]}"} | python3 -c 'import json,sys; print(json.dumps({"items":[l for l in sys.stdin.read().splitlines() if l]}))')
write_status "runner" "warn" "${#findings[@]} runner finding(s)" "$DETAIL"
exit 1
