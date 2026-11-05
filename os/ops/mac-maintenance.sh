#!/usr/bin/env bash
# Weekly Mac health + storage hygiene so backups/dev never fill the disk.
# CONSERVATIVE by design: safe cleanup only (no `brew upgrade`, no
# `docker -a`/`--volumes`). Reports outdated brew formulae instead of upgrading.
# Telegram-alerts (studio bot) if free disk drops below the threshold.
#
# Weekly via launchd: ~/Library/LaunchAgents/${OS_LAUNCHD_PREFIX}.mac-maintenance.plist
# Manual:  bash ~/.claude/scripts/mac-maintenance.sh

# shellcheck source=lib/os-config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/os-config.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-config.sh" 2>/dev/null || true
command -v os_config_load >/dev/null 2>&1 && os_config_load
set -uo pipefail
# S0 (2026-10-26): --help runs nothing; one run at a time (lib/single-instance.sh)
. "$(dirname "${BASH_SOURCE[0]}")/lib/args.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/args.sh" || exit 2
. "$(dirname "${BASH_SOURCE[0]}")/lib/single-instance.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/single-instance.sh" || exit 2
args_help "${BASH_SOURCE[0]}" "$@"
single_instance mac-maintenance
. "$(dirname "$0")/lib/os-state.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-state.sh" 2>/dev/null || true

# TCC canary (2026-07-12): abort when the launchd context cannot see ~/Desktop
OS_JOB_NAME=mac-maintenance
if command -v require_projects_access_critical >/dev/null 2>&1; then require_projects_access_critical || exit 0; fi

export PATH="/opt/homebrew/opt/postgresql@17/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

TS=$(date '+%Y-%m-%d %H:%M')
# 20GB free is the weekly-hygiene threshold. It is NOT the fleet's protection:
# this job runs WEEKLY (Sunday 04:00) and on 2026-09-04 the host fell from
# healthy to 9GB free inside that window, wedging $OS_VM — the guest booted and
# never reached sshd, console.log 0 bytes. The 30-minute host-disk check now
# lives in ci-runner-guard.sh (HOST_DISK_WARN_PCT / HOST_DISK_CRIT_PCT), which
# is the cadence a resource CI writes gigabytes to actually needs. This check
# stays as the slow backstop and the Telegram digest.
THRESHOLD_GB=20
BK="$OS_PROJECTS_DIR/_backups"
echo "==== Mac maintenance $TS ===="

# 1. Backup retention safety-net (per-project script keeps 30; drop strays >60d)
find "$BK" -name "*.sql.gz" -mtime +60 -delete 2>/dev/null || true
echo "backups: $(_ut 30 du -sh "$BK" 2>/dev/null | cut -f1) total, $(find "$BK" -name '*.sql.gz' 2>/dev/null | wc -l | tr -d ' ') dumps"

# 2. Docker: prune dangling images + build cache + stopped containers ONLY.
#    Never -a (would drop unused images) or --volumes (would drop data volumes).
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  out=$(docker system prune -f 2>/dev/null | tail -1)
  echo "docker: ${out:-pruned dangling}"
else
  echo "docker: daemon off — skipped"
fi

# 2b. Self-hosted CI runner VM (Umbra `$OS_VM`; OrbStack retired 2026-07-12).
#     Its docker VOLUMES are ephemeral CI service containers (postgres/redis for
#     tests) that pile up unpruned — 58GB had accumulated by 2026-07-09,
#     ENOSPC-ing the runners AND silently failing cf-deploy (prod not updated).
#     Unlike the Mac's docker above (persistent data volumes → the conservative
#     prune), the runner VM's volumes are throwaway, so `-a --volumes` is safe
#     here. `prune` only drops UNUSED volumes, so a runner mid-job keeps its
#     active volume. NOTE: this was DEAD from 2026-07-12→2026-07-22 (gated on the
#     retired `orb` binary → always skipped); re-pointed at Umbra so the
#     ENOSPC-prevention actually runs again.
UM_CI="${RUNNER_UMBRA_MACHINE:-$OS_VM}"
if command -v umbra >/dev/null 2>&1 && _ut "$OS_UT_SLOW" umbra list 2>/dev/null | grep -qE "^${UM_CI}[[:space:]]+running"; then
  # NOTE (2026-08-03): this block used to wrap everything in
  #   umbra shell "$UM_CI" -- bash -lc '...'
  # which SILENTLY EXECUTES NOTHING. `umbra shell` strips the quoting, so the
  # -lc payload never reaches a shell: `umbra shell <vm> -- bash -lc 'echo hi'`
  # prints nothing and still exits 0. The prune was therefore dead from the day
  # it was written, and 254 orphaned CI service-container volumes filled the
  # guest to 100% (58G/58G, 16 MB free) — which surfaced as `npm install` dying
  # ~63s into unrelated CI jobs, i.e. it looked like flaky tests, not disk.
  # Pass PLAIN space-separated argv, one command per call (no quotes, pipes,
  # globs or ~), and do the looping/filtering HERE on the Mac.
  before=$(_ut "$OS_UT_SLOW" umbra shell "$UM_CI" -- df -h / 2>/dev/null | awk 'NR==2{print $5}')
  con=$(_ut "$OS_UT_SLOW" umbra shell "$UM_CI" -- docker container prune -f 2>/dev/null | tail -1)
  vol=$(_ut "$OS_UT_SLOW" umbra shell "$UM_CI" -- docker volume prune -af 2>/dev/null | tail -1)
  img=$(_ut "$OS_UT_SLOW" umbra shell "$UM_CI" -- docker image prune -af 2>/dev/null | tail -1)
  # _diag logs live under PER-REPO runner dirs (actions-runner-<repo>-1/_diag).
  # The old code looked in ~/actions-runner/_diag, which has not existed since
  # the fleet moved to one runner per repo — a second reason this did nothing.
  for rd in $(_ut "$OS_UT_SLOW" umbra shell "$UM_CI" -- ls /home/umbra 2>/dev/null | grep '^actions-runner-'); do
    _ut "$OS_UT_SLOW" umbra shell "$UM_CI" -- find "/home/umbra/$rd/_diag" -type f -mtime +7 -delete >/dev/null 2>&1 || true
  done
  after=$(_ut "$OS_UT_SLOW" umbra shell "$UM_CI" -- df -h / 2>/dev/null | awk 'NR==2{print $5}')
  echo "runner VM $UM_CI: disk ${before:-?} -> ${after:-?}; ${con:-containers -}; ${vol:-volumes -}; ${img:-images -}"
  # Fail loud if the prune did not buy headroom. A silently-full runner disk
  # breaks every job at install time and reads as flaky CI.
  pct=${after%\%}
  if [ -n "$pct" ] && [ "$pct" -ge 90 ] 2>/dev/null; then
    echo "runner VM $UM_CI: WARNING disk still ${after} after prune - check ~/.npm, ~/.cache, _work dirs"
  fi
else
  echo "runner VM $UM_CI: not running — skipped (prune only needed while up)"
fi

# 3. Homebrew: remove old versions (safe). REPORT outdated; do NOT auto-upgrade
#    (unattended upgrades can break the dev env — review manually).
if command -v brew >/dev/null 2>&1; then
  brew cleanup -s >/dev/null 2>&1 || true
  od=$(brew outdated --quiet 2>/dev/null | tr '\n' ' ')
  echo "brew: cleaned old versions; outdated=${od:-none (up to date)}"
fi

# 4. npm cache verify (safe; reclaims corrupt/old cache entries)
if command -v npm >/dev/null 2>&1; then
  npm cache verify >/dev/null 2>&1 || true
  echo "npm: cache verified"
fi

# 5. Disk report
avail=$(df -g / | awk 'NR==2{print $4}')
echo "disk free: ${avail}GB (alert threshold ${THRESHOLD_GB}GB)"

# 6. Low-disk Telegram alert (studio bot)
if [ "${avail:-999}" -lt "$THRESHOLD_GB" ]; then
  [ -f "$HOME/.mypovonai-telegram.env" ] && . "$HOME/.mypovonai-telegram.env"
  if [ -n "${TG_BOT_TOKEN:-}" ] && [ -n "${TG_CHAT_ID:-}" ]; then
    curl -sS -m 20 -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
      -d chat_id="${TG_CHAT_ID}" \
      --data-urlencode text="⚠️ Mac disk LOW: ${avail}GB free (< ${THRESHOLD_GB}GB). Backups: $(_ut 30 du -sh "$BK" 2>/dev/null | cut -f1). Check Downloads, old node_modules, Docker images." \
      >/dev/null 2>&1 && echo "low-disk alert sent"
  fi
fi
echo "==== done ===="
