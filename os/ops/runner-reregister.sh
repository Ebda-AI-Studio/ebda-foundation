#!/usr/bin/env bash
# runner-reregister.sh — re-register self-hosted runners GitHub has deleted.
#
# WHY THIS EXISTS (second identical outage: 2026-08-02, then 2026-08-04):
# umbra guests are VMs suspended with their host. On resume the clock can be far
# behind — 4h49m on 08-02, ~70m on 08-04. Runner auth tokens are time-sensitive, so
# every runner fails to authenticate, GitHub deletes the registration for
# inactivity, and the runner exits with:
#
#   Failed to create a session. The runner registration has been deleted from the
#   server, please re-configure.
#   Runner listener exit with terminated error, stop the service, no retry needed.
#
# That last line is the whole problem. The service does not retry, and
# ci-runner-guard only knows how to RESTART services — restarting a runner whose
# registration is gone just reproduces the same exit. Nothing re-registers, so CI
# queues forever with no runner and the guard reports "healed" having achieved
# nothing. chrony's `makestep 1 -1` (conf.d/99-vm-suspend.conf) shortens the drift
# window but cannot close it: there is always some interval between resume and the
# first successful NTP step, and it only takes one failed auth cycle.
#
# So recovery has to be able to re-register, not just restart.
#
# Usage:
#   ops/runner-reregister.sh                 # re-register every dead+deleted runner
#   ops/runner-reregister.sh --dry-run       # report what it would do
#   ops/runner-reregister.sh --all           # re-register every runner, dead or not
#
# Requires: umbra on PATH, gh authenticated with repo admin scope.

# shellcheck source=lib/os-config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/os-config.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-config.sh" 2>/dev/null || true
command -v os_config_load >/dev/null 2>&1 && os_config_load
set -uo pipefail

. "$(dirname "$0")/lib/os-state.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-state.sh" 2>/dev/null || true

GUEST="${RUNNER_UMBRA_MACHINE:-$OS_VM}"
LABELS="${RUNNER_LABELS:-wsl2,umbra-ci}"
KNOWN_OWNERS="${RUNNER_OWNERS:-$OS_ORGS}"  # keep in sync with runner-focus.sh
UT="${OS_UT_SLOW:-120}"
DRY=0; ALL=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --all) ALL=1 ;;
    *) echo "unknown flag: $a" >&2; exit 2 ;;
  esac
done

FOCUS_RE="$("$(dirname "$0")/runner-focus.sh" regex 2>/dev/null)"; _frc=$?
[ "$_frc" -eq 0 ] || [ "$_frc" -eq 4 ] || { echo "runner-reregister: runner-focus file unreadable — refusing to touch runners"; exit 1; }
[ "$_frc" -eq 0 ] || FOCUS_RE=""
_run() { if command -v _ut >/dev/null 2>&1; then _ut "$UT" "$@"; else "$@"; fi; }

command -v umbra >/dev/null 2>&1 || {
  # The exact failure that hid this outage for two days: umbra lives in
  # /usr/local/bin, which was missing from the launchd PATH, so the scheduled guard
  # could not see the fleet at all and said so instead of healing.
  echo "runner-reregister: umbra not on PATH (it lives in /usr/local/bin) — cannot reach the fleet"; exit 1
}
command -v gh >/dev/null 2>&1 || { echo "runner-reregister: gh not on PATH"; exit 1; }

# Enumerate runners from the guest's own systemd units — the authoritative list.
# Unit name carries owner-repo and runner name:
#   actions.runner.<owner>-<repo>.<runner-name>.service
units="$(_run umbra shell "$GUEST" -- \
  'systemctl list-units "actions.runner.*" --all --no-legend --no-pager 2>/dev/null | awk "{print \$1}"' 2>/dev/null)"
[ -n "$units" ] || { echo "runner-reregister: no runner units found on $GUEST"; exit 1; }

fixed=0 skipped=0 failed=0
while IFS= read -r unit <&3; do
  [ -n "$unit" ] || continue
  case "$unit" in actions.runner.*) ;; *) continue ;; esac

  # Runner focus: a deactivated runner is down on purpose — never re-register it.
  if [ -n "${FOCUS_RE:-}" ] && ! printf '%s\n' "$unit" | grep -qE "$FOCUS_RE"; then
    echo "  SKIP $unit — deactivated by runner-focus"; skipped=$((skipped+1)); continue
  fi
  middle="${unit#actions.runner.}"; middle="${middle%.service}"
  ownerrepo="${middle%%.*}"          # e.g. <owner>-<repo>
  runner="${middle#*.}"              # e.g. <vm>-crm-1
  # Owner and repo are joined by a dash in the unit name, and BOTH sides contain
  # dashes — splitting on the first one yields owner "ForceAI" / repo "KW-...".
  # Match the known owners by prefix instead of guessing where the boundary is.
  owner=""; repo=""
  for known in $KNOWN_OWNERS; do
    case "$ownerrepo" in
      "$known"-*) owner="$known"; repo="${ownerrepo#${known}-}"; break ;;
    esac
  done
  if [ -z "$owner" ]; then echo "  SKIP $unit — unrecognised owner prefix"; skipped=$((skipped+1)); continue; fi
  dir="actions-runner-${repo}-1"

  state="$(_run umbra shell "$GUEST" -- "systemctl is-active $unit 2>/dev/null" 2>/dev/null | tr -d '\r\n')"
  gh_state="$(_run gh api "repos/$owner/$repo/actions/runners" \
    --jq "[.runners[]? | select(.name==\"$runner\") | .status] | first // \"absent\"" 2>/dev/null)"

  if [ "$ALL" -eq 0 ] && [ "$state" = "active" ] && [ "$gh_state" = "online" ]; then
    skipped=$((skipped+1)); continue
  fi

  echo "  $runner ($owner/$repo): unit=$state github=$gh_state"
  if [ "$DRY" -eq 1 ]; then echo "    DRY: would re-register"; continue; fi

  local_rm="$(_run gh api -X POST "repos/$owner/$repo/actions/runners/remove-token" --jq .token 2>/dev/null)"
  local_reg="$(_run gh api -X POST "repos/$owner/$repo/actions/runners/registration-token" --jq .token 2>/dev/null)"
  if [ -z "$local_reg" ]; then echo "    FAILED — could not mint a registration token"; failed=$((failed+1)); continue; fi

  # umbra shell mangles quoting on compound commands, so ship a script over stdin.
  payload="$(mktemp)"
  cat > "$payload" <<INNER
set -e
cd /home/umbra/$dir
sudo ./svc.sh stop >/dev/null 2>&1 || true
sudo ./svc.sh uninstall >/dev/null 2>&1 || true
# The server-side registration is already gone, so remove is expected to fail —
# clearing the local credentials is what it would have done anyway.
./config.sh remove --token $local_rm >/dev/null 2>&1 || rm -f .runner .credentials .credentials_rsaparams
./config.sh --unattended --url https://github.com/$owner/$repo --token $local_reg \\
  --name $runner --labels $LABELS --work _work >/dev/null
sudo ./svc.sh install umbra >/dev/null
sudo ./svc.sh start >/dev/null
INNER
  # shellcheck disable=SC2002
  cat "$payload" | _run umbra shell "$GUEST" -- bash -lc 'cat > /tmp/runner-reregister-payload.sh' >/dev/null 2>&1
  rm -f "$payload"

  if _run umbra shell "$GUEST" -- bash /tmp/runner-reregister-payload.sh >/dev/null 2>&1; then
    # Confirm against GitHub, not against the script's exit code — the whole failure
    # mode here is a command that succeeds while the runner stays unusable.
    sleep 5
    after="$(_run gh api "repos/$owner/$repo/actions/runners" \
      --jq "[.runners[]? | select(.name==\"$runner\") | .status] | first // \"absent\"" 2>/dev/null)"
    if [ "$after" = "online" ]; then echo "    re-registered — online"; fixed=$((fixed+1))
    else echo "    re-registered but GitHub still reports '$after'"; failed=$((failed+1)); fi
  else
    echo "    FAILED to re-register"; failed=$((failed+1))
  fi
done 3< <(printf '%s\n' "$units")

echo
echo "runner-reregister: $fixed re-registered, $skipped healthy, $failed failed"
if command -v write_status >/dev/null 2>&1; then
  ok=ok; [ "$failed" -gt 0 ] && ok=warn
  write_status runner-reregister "$ok" "$fixed re-registered, $skipped healthy, $failed failed" \
    "{\"fixed\":$fixed,\"skipped\":$skipped,\"failed\":$failed}"
fi
[ "$failed" -eq 0 ]
