#!/usr/bin/env bash
# Ebda OS — runner post-job-hook health detector (Whisky AI OS).
#
# Detects the specific infra signature where a self-hosted runner's post-job hook
# (ACTIONS_RUNNER_HOOK_JOB_COMPLETED) exits non-zero and fails jobs at the
# "Complete runner" step — AFTER every real step passed. That turns green code into
# un-mergeable PRs (each required check shows red for a reason unrelated to the PR).
# It silently blocked EVERY PR on store + whatsapp until found on 2026-06-11.
#
# This is the reactive complement to ci-runner-guard.sh: that one handles
# cloud-minutes exhaustion → self-hosted failover; THIS one handles a broken
# self-hosted post-job hook. When it fires it alerts Ahmad with the one-line fix.
#
# Signature (per recent CI run, per job):
#   job.conclusion == failure|cancelled
#   AND every step whose name is NOT a post/cleanup step succeeded
#   AND the only failed step is "Complete runner" (or a "Post "/cleanup step)
#
# Runs on the Mac (reads the GH API). Schedule via launchd or call on demand:
#   bash ops/runner-hook-health.sh            # report
#   bash ops/runner-hook-health.sh --notify   # report + Telegram on detection
# shellcheck source=lib/os-config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/os-config.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-config.sh" 2>/dev/null || true
command -v os_config_load >/dev/null 2>&1 && os_config_load
set -uo pipefail
. "$(dirname "$0")/lib/os-state.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-state.sh" 2>/dev/null || true

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OWNER="$OS_ORG"
REPOS=(ebda-store ebda-whatsapp ebda-studio)
RUNS_PER_REPO="${RUNS_PER_REPO:-8}"
NOTIFY=0; [ "${1:-}" = "--notify" ] && NOTIFY=1

# A step name that is post-job / cleanup (allowed to be the ONLY failure signature).
is_cleanup_step() {
  case "$1" in
    "Complete runner"|"Complete job"|"Post "*|*"cleanup"*|*"Cleanup"*) return 0 ;;
    *) return 1 ;;
  esac
}

hits=()       # "repo#run jobName" — post-job-hook signature
disk_hits=()  # "repo#run" — runner out-of-disk signature (added 2026-07-11:
              # a routine deploy died mid-checkout with "No space left on device"
              # despite weekly maintenance; detect + alert with the fix)
browser_hits=()  # "repo#run" — runner TOOLCHAIN/BROWSER-CACHE corruption (G7,
              # 2026-07-22): whatsapp #139 died every run on a corrupt puppeteer chrome
              # download ("end of central directory record signature not found");
              # runner env rot a code fix can't clear — detect + alert the cache wipe.

for repo in "${REPOS[@]}"; do
  runs=$(_ut "$OS_UT_FAST" gh api "repos/$OWNER/$repo/actions/runs?status=completed&per_page=$RUNS_PER_REPO" \
           --jq '.workflow_runs[] | select(.conclusion=="failure" or .conclusion=="cancelled") | .id' 2>/dev/null) || continue
  for runid in $runs; do
    jobs_json=$(_ut "$OS_UT_FAST" gh api "repos/$OWNER/$repo/actions/runs/$runid/jobs?per_page=50" 2>/dev/null) || continue
    run_realfail=0
    # For each failed job: did a NON-cleanup step fail? If no real step failed but
    # the job is failure → the post-job hook killed it. That's our signature.
    while IFS=$'\t' read -r jobname realfail cleanupfail; do
      [ -z "$jobname" ] && continue
      if [ "$realfail" = "0" ] && [ "$cleanupfail" -gt 0 ]; then
        hits+=("$repo #$runid · $jobname")
      fi
      [ "$realfail" -gt 0 ] && run_realfail=1
    done < <(echo "$jobs_json" | python3 -c '
import json, sys
def cleanup(n):
    n = n or ""
    return n in ("Complete runner", "Complete job") or n.startswith("Post ") or "cleanup" in n.lower()
d = json.load(sys.stdin)
for j in d.get("jobs", []):
    if j.get("conclusion") not in ("failure", "cancelled"):
        continue
    realfail = cleanfail = 0
    for s in j.get("steps", []):
        if s.get("conclusion") == "failure":
            if cleanup(s.get("name")):
                cleanfail += 1
            else:
                realfail += 1
    nm = j.get("name") or ""
    sys.stdout.write("%s\t%d\t%d\n" % (nm, realfail, cleanfail))
' 2>/dev/null)
    # Disk-full signature: only grep logs of runs where a REAL step failed
    # (checkout/build dying on a full runner disk shows as a real failure).
    if [ "$run_realfail" = "1" ]; then
      logs=$(_ut "$OS_UT_FAST" gh run view --repo "$OWNER/$repo" "$runid" --log-failed 2>/dev/null)
      printf '%s' "$logs" | grep -qim1 'no space left on device' && disk_hits+=("$repo #$runid")
      # G7 browser/toolchain corruption: a broken cached browser download the runner
      # keeps re-using — no code change clears it, only wiping the host cache does.
      printf '%s' "$logs" | grep -qiE 'end of central directory record signature not found|Failed to set up chrome|Could not find (Chrome|Chromium|browser)|ECONNRESET.*(chrome|puppeteer)|puppeteer.*(install|download).*(fail|error)' \
        && browser_hits+=("$repo #$runid")
    fi
  done
done

echo "== runner-hook-health =="
if [ "${#disk_hits[@]}" -gt 0 ]; then
  echo "DETECTED runner OUT-OF-DISK failures:"
  for h in ${disk_hits[@]+"${disk_hits[@]}"}; do echo "  • $h"; done
  DISK_FIX="ON THE RUNNER HOST (umbra shell $OS_VM --): prune the runner _work dir + docker (docker system prune -af; rm -rf ~/actions-runner/_work/*/*) and check 'df -h'. Weekly maintenance cadence was not enough — consider a job-started df gate in the runner hook."
  echo "FIX: $DISK_FIX"
  if [ "$NOTIFY" = "1" ] && [ -x "$HERE/notify.sh" ]; then
    "$HERE/notify.sh" "Self-hosted runner is OUT OF DISK — CI failing" \
      "$(printf '%s\n' ${disk_hits[@]+"${disk_hits[@]}"})"$'\n\n'"$DISK_FIX" >/dev/null 2>&1 || true
  fi
fi
if [ "${#browser_hits[@]}" -gt 0 ]; then
  echo "DETECTED runner BROWSER/TOOLCHAIN-cache corruption failures:"
  for h in ${browser_hits[@]+"${browser_hits[@]}"}; do echo "  • $h"; done
  BROWSER_FIX="ON THE RUNNER HOST (umbra shell $OS_VM --): the runner is re-using a corrupt cached browser download that no code change can clear. Wipe it: rm -rf ~/.cache/puppeteer/chrome* ~/.cache/ms-playwright 2>/dev/null; then the next install re-fetches cleanly. Durable fix: skip the download in CI (puppeteer .puppeteerrc.cjs skipDownload / PUPPETEER_SKIP_DOWNLOAD) when the browser isn't needed."
  echo "FIX: $BROWSER_FIX"
  if [ "$NOTIFY" = "1" ] && [ -x "$HERE/notify.sh" ]; then
    "$HERE/notify.sh" "Self-hosted runner BROWSER CACHE corrupt — CI failing" \
      "$(printf '%s\n' ${browser_hits[@]+"${browser_hits[@]}"})"$'\n\n'"$BROWSER_FIX" >/dev/null 2>&1 || true
  fi
fi
if [ "${#hits[@]}" -eq 0 ]; then
  if [ "${#disk_hits[@]}" -eq 0 ] && [ "${#browser_hits[@]}" -eq 0 ]; then
    echo "OK — no post-job-hook, disk-full, or browser-cache signature in the last $RUNS_PER_REPO runs/repo."
    write_status "runner-hook" "true" "clean — no post-job-hook / disk-full / browser-cache signature in the last $RUNS_PER_REPO runs/repo" '{}'
  else
    DETAIL=$( { printf 'D\t%s\n' "${disk_hits[@]:-}"; printf 'B\t%s\n' "${browser_hits[@]:-}"; } | python3 -c 'import json,sys
disk=[]; br=[]
for l in sys.stdin:
    l=l.rstrip("\n")
    if l.startswith("D\t") and l[2:].strip(): disk.append(l[2:])
    elif l.startswith("B\t") and l[2:].strip(): br.append(l[2:])
print(json.dumps({"disk":disk,"browser":br}))' 2>/dev/null || echo "{}")
    write_status "runner-hook" "false" "${#disk_hits[@]} disk-full + ${#browser_hits[@]} browser-cache runner failure(s) detected" "$DETAIL"
  fi
  exit 0
fi

echo "DETECTED post-job-hook job failures (real steps passed, only cleanup failed):"
for h in ${hits[@]+"${hits[@]}"}; do echo "  • $h"; done
FIX="ON THE RUNNER HOST (umbra shell $OS_VM --): bash ebda-foundation/ops/setup-runner-hooks.sh — wraps the hook so it always exits 0 (cleanup stays best-effort). No runner restart needed."
echo
echo "FIX: $FIX"

if [ "$NOTIFY" = "1" ] && [ -x "$HERE/notify.sh" ]; then
  body="$(printf '%s\n' ${hits[@]+"${hits[@]}"})"$'\n\n'"$FIX"
  "$HERE/notify.sh" "Runner post-job hook is failing jobs" "$body" >/dev/null 2>&1 || true
fi
DETAIL=$(printf '%s\n' ${hits[@]+"${hits[@]}"} | python3 -c 'import json,sys; print(json.dumps({"items":[l for l in sys.stdin.read().splitlines() if l]}))')
write_status "runner-hook" "false" "${#hits[@]} post-job-hook failure(s) detected" "$DETAIL"
exit 0
