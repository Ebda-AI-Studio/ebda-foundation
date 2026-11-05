#!/usr/bin/env bash
# Force AI — self-hosted runner JOB-STARTED hook: reclaim disk before the job runs.
#
# Deployed INSIDE the Umbra CI guest as /home/umbra/hooks/job-started.sh and
# wired via ACTIONS_RUNNER_HOOK_JOB_STARTED in each runner's .env.
#
# WHY (2026-08-03): ebda-studio CI failed with "No space left on device"
# while writing its own _diag log. The weekly maintenance cadence was not
# enough — the guest fills between sweeps, and the failure lands mid-job as a
# confusing error in an unrelated step. Reclaiming at JOB START turns a
# random mid-build explosion into a bounded, predictable cleanup.
#
# ── FAIL-OPEN BY DESIGN ───────────────────────────────────────────────────────
# A job hook that exits non-zero FAILS THE JOB. That exact thing has already
# cost this fleet dearly: a post-job hook returning non-zero failed every PR at
# the "Complete runner" step, AFTER all real steps passed, silently blocking
# every merge on FWB + WBS until found (see runner-hook-health.sh). So:
#
#   • Any internal error here exits 0. A bug in this file must never be able to
#     block CI — the worst it may do is fail to free space.
#   • It exits non-zero in exactly ONE case: after cleaning, free space is still
#     below HARD_MIN_GB. Failing fast with a clear message beats an ENOSPC ten
#     minutes into a build, reported against an innocent step.
set -uo pipefail
trap 'exit 0' ERR   # fail-open: never let an unexpected error fail the job

SOFT_MIN_GB="${RUNNER_DISK_SOFT_MIN_GB:-15}"   # below this → clean
HARD_MIN_GB="${RUNNER_DISK_HARD_MIN_GB:-4}"    # still below after cleaning → refuse
WORK_KEEP_DAYS="${RUNNER_WORK_KEEP_DAYS:-3}"

free_gb() { df -BG --output=avail / 2>/dev/null | tail -1 | tr -dc '0-9' || echo 999; }

avail="$(free_gb)"; avail="${avail:-999}"
echo "[disk-gate] free ${avail}G (soft ${SOFT_MIN_GB}G / hard ${HARD_MIN_GB}G)"
[ "$avail" -ge "$SOFT_MIN_GB" ] && exit 0

echo "[disk-gate] below soft floor — reclaiming"

# 1) Docker: images/containers/build cache no longer referenced.
command -v docker >/dev/null 2>&1 && docker system prune -af --volumes >/dev/null 2>&1 || true

# 2) OTHER runners' stale workspaces. Never this runner's own $RUNNER_WORKSPACE
#    (that is the job about to run), and only trees untouched for
#    WORK_KEEP_DAYS — a workspace touched today probably belongs to a job
#    running right now on a sibling runner.
self="${RUNNER_WORKSPACE:-}"
for w in /home/umbra/actions-runner-*/_work/*; do
  [ -d "$w" ] || continue
  case "$w" in "$self"*) continue ;; esac
  [ -n "$(find "$w" -maxdepth 0 -mtime +"$WORK_KEEP_DAYS" 2>/dev/null)" ] || continue
  rm -rf "$w" 2>/dev/null && echo "[disk-gate]   pruned stale workspace $w"
done

# 3) Package-manager caches — always safe, always re-downloadable.
command -v pnpm >/dev/null 2>&1 && pnpm store prune >/dev/null 2>&1 || true
command -v npm  >/dev/null 2>&1 && npm cache clean --force >/dev/null 2>&1 || true
rm -rf /home/umbra/.cache/ms-playwright/* 2>/dev/null || true

# 4) Runner diagnostic logs — the CRM failure was literally a _diag write.
find /home/umbra/actions-runner-*/_diag -type f -mtime +7 -delete 2>/dev/null || true

avail="$(free_gb)"; avail="${avail:-999}"
echo "[disk-gate] free after cleanup: ${avail}G"

if [ "$avail" -lt "$HARD_MIN_GB" ]; then
  echo "[disk-gate] FATAL: only ${avail}G free after cleanup (need ${HARD_MIN_GB}G)." >&2
  echo "[disk-gate] Refusing to start — a build that runs out of disk mid-way fails" >&2
  echo "[disk-gate] against an unrelated step and wastes the whole run." >&2
  echo "[disk-gate] On the host: umbra shell fwb-ci6 -- 'df -h /; sudo du -sh /home/umbra/* | sort -rh | head'" >&2
  exit 1
fi
exit 0
