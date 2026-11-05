#!/usr/bin/env bash
# Whisky AI OS — CI runner guard (bidirectional).
#
# Problem this solves (observed 2026-06-09): GitHub-hosted Actions minutes ran out, so
# every `ubuntu-latest` job died instantly at the infrastructure level (no runner name,
# no failed step, empty logs) — making green PRs un-mergeable for reasons unrelated to the
# code. The fix was manual: set the repo's USE_SELF_HOSTED variable to 'true' so CI routes
# to the free self-hosted runners (now the Umbra $OS_VM VM on this Mac; OrbStack retired 2026-07-12). This guard automates that detection + flip.
#
# It is now BIDIRECTIONAL (2026-06-13). Two directions:
#
#   A. Cloud exhausted → self-hosted  (original direction)
#      Detects cloud-minutes exhaustion via billing API or infra-failure heuristic, then
#      sets USE_SELF_HOSTED=true when a self-hosted runner is online.
#
#   B. Self-hosted saturated → cloud  (NEW — fixes recurring saturation stalls)
#      Detects when ALL self-hosted runners are busy AND CI jobs are stuck queued or
#      repeatedly cancelled for >SATURATION_QUEUE_MIN minutes. Sets USE_SELF_HOSTED=false
#      to route new CI to cloud runners.
#      Flip-back: when runners are free + queue is clear AND USE_SELF_HOSTED=false (set by B),
#      sets USE_SELF_HOSTED=true and alerts. Guard against flapping: only one flip per cycle,
#      direction A takes priority (cloud exhaustion overrides saturation flip-back).
#
# What it does, per Force repo:
#   1. If USE_SELF_HOSTED is 'false': check cloud exhaustion → maybe flip to self-hosted.
#      Then if cloud is healthy + runners free + queue clear: flip back from saturation.
#   2. If USE_SELF_HOSTED is 'true': check self-hosted saturation → maybe flip to cloud.
#      If no saturation: report healthy (or alert if all runners offline).
#   3. Always announces any flip through the Whisky Whoop bot.
#
# Read-mostly: the only mutations are `gh variable set USE_SELF_HOSTED <true|false>`,
# always gated on detection and always announced.
# shellcheck source=lib/os-config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/os-config.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-config.sh" 2>/dev/null || true
command -v os_config_load >/dev/null 2>&1 && os_config_load
set -uo pipefail
. "$(dirname "$0")/lib/os-state.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-state.sh" 2>/dev/null || true
# Fleet park state — a thin wrapper over service_paused() from os-state.sh above,
# so the marker lives with every other paused service (~/.whisky-os-state/). FAIL
# CLOSED on a missing lib: if fleet_parked is undefined the guard must behave exactly
# as it did before parking existed (heal + alert), never treat in-service as parked.
. "$(dirname "$0")/lib/runner-fleet.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/runner-fleet.sh" 2>/dev/null || true
. "$(dirname "$0")/lib/safe-prune.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/safe-prune.sh" 2>/dev/null || true
. "$(dirname "$0")/lib/disk-pressure.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/disk-pressure.sh" 2>/dev/null || true
. "$(dirname "$0")/lib/clock-drift.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/clock-drift.sh" 2>/dev/null || true
. "$(dirname "$0")/lib/guest-rebuild.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/guest-rebuild.sh" 2>/dev/null || true
command -v fleet_parked >/dev/null 2>&1 || { fleet_parked() { return 1; }; fleet_park_reason() { printf 'unknown'; }; }
# `umbra rebuild` in progress (2026-10-16). FAIL OPEN on a missing lib: no lib
# means no marker can be honoured, so the guard behaves exactly as before.
. "$(dirname "$0")/lib/umbra-provisioning.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/umbra-provisioning.sh" 2>/dev/null || true
command -v umbra_provisioning >/dev/null 2>&1 || umbra_provisioning() { return 1; }
# hands_off <machine> <action> — 0 (and logs why, on STDERR so it never pollutes
# a $(…) capture) when `umbra rebuild` is provisioning <machine> RIGHT NOW.
# Called immediately before every action that changes a guest: the pre-flight
# read alone left a window of minutes (doctor, 180s boots) in which a rebuild
# could start and the guard would still stop/start/rebuild on top of it.
hands_off() {
  local r; r="$(umbra_provisioning "$1")" || return 1
  echo "[ci-runner-guard] skipping $2 on $1 — $r" >&2
  return 0
}
# FAIL CLOSED on a missing guest-rebuild lib. `umbra rebuild` destroys the guest,
# so a missing GUARDRAIL must mean NO rebuild — never an unguarded one. The stub
# reports the budget as already spent, which routes to the loud "needs a human"
# branch instead of to the destructive one.
command -v guest_rebuild_allowed >/dev/null 2>&1 || {
  guest_rebuild_allowed() { printf 'limit:unknown\n'; }
  guest_rebuild_record()  { :; }
  guest_rebuild_history() { printf ''; }
}
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/guest-wedge.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/guest-wedge.sh" 2>/dev/null || true
command -v umbra_start_flags >/dev/null 2>&1 || umbra_start_flags() { return 0; }   # umbra U1: --fsck-if-dirty when supported
GH_USER="$OS_ORG"

# ── RUNNER FOCUS (2026-10-08) ────────────────────────────────────────────────
# Only the focused repos' runners are EXPECTED to run (ops/runner-focus.sh; state
# in ~/.umbra/runner-focus.json). A deactivated runner is down ON PURPOSE: it is not
# counted in the expected/active totals, never restarted by a heal, never
# re-registered. No focus file = every runner expected (old behaviour).
# FOCUS_PFX is prepended to every guest command that lists units; FRE filters them.
# A focus file that exists but cannot be read must NOT fall back to "heal all"
# (that would start every deactivated runner): healing is disabled and we alert.
FOCUS_PFX=""; FOCUS_BROKEN=0; FOCUS_ON=0
_focus_re="$("$HERE/runner-focus.sh" regex 2>/dev/null)"; _focus_rc=$?
case "$_focus_rc" in
  0) FOCUS_ON=1; FOCUS_PFX="FRE='${_focus_re}'; " ;;
  4) FOCUS_PFX="FRE='.'; " ;;
  *) FOCUS_BROKEN=1; FOCUS_PFX="FRE='.'; " ;;
esac

# repo slugs that run CI (default branch has a ci.yml honoring vars.USE_SELF_HOSTED)
REPOS=(ebda-store ebda-whatsapp ebda-studio)

# Saturation threshold: jobs stuck queued/recently-cancelled = saturation if older than this
SATURATION_QUEUE_MIN="${SATURATION_QUEUE_MIN:-15}"

findings=()   # repos we flipped or that need attention
notes=()      # informational per-repo status

flipped() { findings+=("$1"); }
note()    { notes+=("$1"); }

# ── optional billing signal (needs a PAT with billing scope; gh keyring token lacks it) ──
billing_exhausted() {
  [ -n "${GH_BILLING_PAT:-}" ] || return 1
  local j; j=$(GH_TOKEN="$GH_BILLING_PAT" gh api "users/$GH_USER/settings/billing/actions" 2>/dev/null) || return 1
  printf '%s' "$j" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin); used=d.get('total_minutes_used',0); inc=d.get('included_minutes',0)
    sys.exit(0 if (inc and used>=inc) else 1)
except Exception: sys.exit(1)" 2>/dev/null
}

# ── heuristic: recent cloud CI runs failed at infra level (no real step failure) ──
# Returns 0 (exhausted-suspected) if >=2 of the last 6 CI runs are infra-failures.
cloud_ci_infra_failing() {
  local slug="$1"
  local runs; runs=$(gh run list --repo "$slug" --workflow CI --limit 6 \
    --json databaseId,conclusion 2>/dev/null) || return 1
  local ids; ids=$(printf '%s' "$runs" | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(' '.join(str(r['databaseId']) for r in d if r.get('conclusion') in ('failure','startup_failure')))" 2>/dev/null)
  [ -z "$ids" ] && return 1
  local infra=0
  for id in $ids; do
    # an INFRA failure = the run failed but NO job has a step with conclusion 'failure'.
  # 'cancelled' is NOT counted (2026-10-03): concurrency groups, superseded PR
  # pushes and a human/babysitter cancelling runs all produce it, and counting it
  # flipped store back to self-hosted 7 minutes after the owner moved CI to cloud.
    local realfail; realfail=$(gh run view "$id" --repo "$slug" --json jobs 2>/dev/null | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    steps=[s for j in d.get('jobs',[]) for s in j.get('steps',[])]
    print('yes' if any(s.get('conclusion')=='failure' for s in steps) else 'no')
except Exception: print('no')" 2>/dev/null)
    [ "$realfail" = "no" ] && infra=$((infra+1))
  done
  [ "$infra" -ge 2 ]
}

# Is at least one self-hosted runner online for this repo?
runner_online() {
  local slug="$1"
  gh api "repos/$slug/actions/runners" --jq '[.runners[]|select(.status=="online")]|length' 2>/dev/null | grep -qvE '^0?$'
}

# The self-hosted runner lives in a local Umbra VM on this Mac. Canonical host
# since the 2026-07-30 rebuild is $OS_VM (the runner is a systemd unit inside
# it, so booting the VM restarts it). umbra-ci5, umbra-ci2 + the OrbStack umbra-ci machine are
# retired. Heal Umbra first so this guard never resurrects a stale host.
# Returns 0 when a runner is back online. Overrides: RUNNER_UMBRA_MACHINE /
# RUNNER_ORB_MACHINE.
# Is the Umbra runner machine up? Its runner instances are registered at the
# ORG level, which the repo-scoped /actions/runners API cannot see — so a
# running Umbra machine means runner_online() can be a FALSE negative.
# ── EVERY umbra call is wall-clocked ─────────────────────────────────────────
# 2026-08-03: three copies of this guard sat wedged for 4h07m on a single
# `umbra shell`. umbra spawns its own ssh to the guest, that ssh had no
# ConnectTimeout, and the cached port was stale — so it blocked forever instead
# of failing. launchd will not start a new run while one is in flight, so the
# 30-minute guard silently stopped guarding: no log, no alert, and `launchctl`
# still reporting the job "running". The guest was healthy the whole time.
#
# A monitor that can block indefinitely on the subsystem it monitors has no
# failure mode left that anyone will notice — it just goes quiet, and quiet
# reads exactly like healthy. Nothing here may outlive its wall clock.
#
# Exit 124 (the timeout convention) is deliberately NOT treated as "0 runners":
# every caller already distinguishes UNKNOWN (-1) from a real count, and a
# timed-out probe is the definition of unknown. Healing on it would restart
# live runners mid-job.
UMBRA_TIMEOUT="${UMBRA_TIMEOUT:-45}"
# `umbra doctor` gets its OWN ceiling: it measured 65-66s on a degraded guest
# (2026-10-16), so under the 45s probe ceiling it returned nothing and both the
# unhealable pre-flight and the attention page silently failed open. 180s fits
# the 30-min cadence.
UMBRA_TIMEOUT_DOCTOR="${UMBRA_TIMEOUT_DOCTOR:-180}"      # per-call ceiling for read probes
UMBRA_TIMEOUT_SLOW="${UMBRA_TIMEOUT_SLOW:-180}"  # boots/reboots legitimately take longer

#
# 2026-09-15: it hung AGAIN, 27+ minutes, on `ssh … umbra@127.0.0.1 bash`. The
# ssh line proves the call site: `umbra shell` execs ssh with whatever follows
# `--`, so a bare trailing `bash` only comes from the stdin-fed
# `printf … | umbra shell m -- bash` reads (clock, guest disk, semgrep) — and
# NONE of those were wrapped. "Every umbra call" was a comment, not a check;
# ops/tests/ci-runner-guard.test.sh now fails on any unwrapped `umbra` call.
# The same day showed _ut itself could not bound the caller: see the copy in
# lib/os-state.sh for the stdin and leaked-descendant holes. This copy is kept
# byte-identical to that one (the test enforces it) so a missing lib cannot
# leave the guard unbounded.
_ut() {
  local secs="$1"; shift
  "$@" <&0 & local p=$! t=0 k
  while kill -0 "$p" 2>/dev/null; do
    if [ "$t" -ge $((secs * 5)) ]; then
      k="$(_ut_tree "$p") $p"
      # shellcheck disable=SC2086  # $k is a pid list, split on purpose
      { kill -TERM $k; sleep 2; kill -KILL $k; } 2>/dev/null
      return 124
    fi
    sleep 0.2; t=$((t+1))
  done
  wait "$p"
}
_ut_tree() {
  # _ut_tree <pid> — every descendant pid, deepest first.
  local c
  for c in $(pgrep -P "$1" 2>/dev/null); do _ut_tree "$c"; echo "$c"; done
}

umbra_fleet_running() {
  command -v umbra >/dev/null 2>&1 && \
    _ut "$UMBRA_TIMEOUT" umbra list 2>/dev/null | grep -qE "^${RUNNER_UMBRA_MACHINE:-$OS_VM}[[:space:]]+running"
}

# The runner VM's lifecycle state as `umbra list` prints it — stopped, starting,
# running, stopping, crashed — or empty when it is unlisted or umbra is unreachable.
umbra_vm_state() {
  command -v umbra >/dev/null 2>&1 || return 0
  _ut "$UMBRA_TIMEOUT" umbra list 2>/dev/null \
    | awk -v m="${RUNNER_UMBRA_MACHINE:-$OS_VM}" 'NR>1 && $1==m {print $2; exit}'
}

# The state once any in-flight stop/start has finished, bounded by
# UMBRA_TIMEOUT_SLOW. Still `starting`/`stopping` on return means it is STUCK.
#
# 2026-09-15: a human ran `umbra stop $OS_VM && umbra start $OS_VM`, the stop
# took its full 120s graceful window, and this guard paged "NOT running and not
# startable" — it knew only `running` and `stopped`, and read `stopping` as an
# outage. umbra holds the machine in `stopping` for up to 180s (120s graceful +
# 60s escalation) and `starting` while it launches; neither is a fault, and
# `umbra start` mid-stop just queues behind the stop.
#
# A `stopped` seen straight after a transition gets ONE more poll: `stop && start`
# passes through stopped for an instant, and starting the VM ourselves then would
# race the human's own start.
UMBRA_SETTLE_POLL="${UMBRA_SETTLE_POLL:-10}"
umbra_vm_settled_state() {
  local s prev="" w=0
  s="$(umbra_vm_state)"
  while [ "$w" -lt "$UMBRA_TIMEOUT_SLOW" ]; do
    case "$s" in
      starting|stopping) ;;
      stopped) case "$prev" in starting|stopping) ;; *) break ;; esac ;;
      *) break ;;
    esac
    sleep "$UMBRA_SETTLE_POLL"; w=$((w + UMBRA_SETTLE_POLL))
    prev="$s"; s="$(umbra_vm_state)"
  done
  printf '%s' "$s"
}

# Runners umbra was TOLD to install on the machine: the sum of `count` across the
# entries of ~/.umbra/runners/<machine>.json (written by `umbra runner add`).
# Echoes nothing when the manifest is absent or unreadable.
umbra_manifest_runners() {
  local f="$HOME/.umbra/runners/${RUNNER_UMBRA_MACHINE:-$OS_VM}.json"
  [ -f "$f" ] || return 0
  python3 -c '
import json, sys
try:
    n = sum(int(e.get("count", 0)) for e in json.load(open(sys.argv[1])).get("entries", []))
    print(n) if n > 0 else None
except Exception:
    pass' "$f" 2>/dev/null
}

# ── umbra doctor integration (umbra >= 0.8.0) ────────────────────────────────
# `umbra doctor --json` classifies a fault into one rung of a triage ladder.
# We use it for ONE thing the legacy probes below cannot do: recognise faults
# that NO amount of restarting can fix, so the guard stops trying.
#
# Why this matters: when the host itself is faulting, reboot_guest() fails, the
# guard alerts "investigate", and then does the whole thing again 30 minutes
# later — stop/starting a degrading machine forever. Observed 2026-07-19/20:
# a full power-cycle bought ~90 minutes before guests wedged again under CI
# load, and two independent guests failed identically (host-level, not image).
#
# This is FEATURE-DETECTED and fail-open: on an umbra without `doctor`, or any
# parse failure, it returns non-zero and the legacy logic below governs
# unchanged. It must never make the guard worse than before it existed.
#
# NEVER pass --deep here. --deep boots a spare guest; there is no spare now and
# stopped-by-design ("do NOT default to it or the guard starts a machine Ahmad
# keeps off"). Default doctor is read-only and safe for a 30-minute cron.
# Rungs that restarting cannot fix, so the guard stands down instead of thrashing.
#
# billing-lockout is deliberately NOT here. It is a CLOUD-runner fault and the
# self-hosted guest is a separate failure domain: a blocked ubuntu-latest quota
# is neither caused nor worsened by rebooting a wedged VM, and gating on it
# means one unrelated repo suppresses healing for the whole fleet. On 2026-08-03
# three landing-page repos carried a genuine lockout while the guest was hung,
# and this list would have kept the guard standing down through the outage.
# (Flipping TO cloud is still correctly blocked — that path checks minutes
# itself.)
# Rungs the guard MUST NOT try to heal. Restarting a runner is the guard's only
# lever, and for each of these it is either useless or actively harmful:
#
#   host-hardware       the machine is miscomputing; only a power-cycle applies.
#   netstack-dead       the host's user-mode network stack is down for all guests.
#   guest-disk-corrupt  the guest root filesystem carries the ext4 error flag, so
#                       Ubuntu remounts root read-only (errors=remount-ro) and
#                       sshd never starts. RESTARTING MAKES IT WORSE: every
#                       unclean shutdown adds damage. This is not hypothetical —
#                       $OS_VM was restart-looped every 30 minutes from
#                       2026-08-27 to 2026-09-07 while its filesystem degraded,
#                       because doctor could only call the fault `unknown`.
#                       Needs umbra >= the guest-disk-corrupt rung (umbra#28);
#                       older binaries simply never emit it, so listing it here
#                       is harmless on an older fleet.
#   machine-crashed     covers the zombie case, where the remedy is a REPEATED
#                       STOP — the exact opposite of the guard's restart loop.
#                       Starting is refused until a stop confirms, so looping
#                       here burns the window without ever converging.
#   guest-binaries-missing  the guest's own package database (dpkg) says files
#                       are installed that are actually gone from disk (umbra
#                       doctor >= the wave that added this rung, 2026-09-22).
#                       RESTARTING DOES NOTHING: the files stay missing across
#                       a reboot, same as guest-disk-corrupt. This is the exact
#                       fault that froze CI fleet-wide on 2026-09-22 — the
#                       throttle hook's claim loop silently lost `seq` and
#                       every job hung at "Set up runner" until GitHub's own
#                       timeout killed it, on every one of the 15 repos this
#                       guest serves. Like guest-disk-corrupt, it is layered
#                       with a guarded auto-rebuild below (rebuild_corrupt_guest
#                       now handles both rungs) rather than a bare stand-down,
#                       because a rebuild is the only remedy that actually
#                       replaces the missing files.
#
# billing-lockout is deliberately NOT here, though it was briefly added in #146.
# Two reasons, both found by watching it fire on a live host on 2026-09-07:
#   1. WRONG SCOPE. A billing lockout blocks GITHUB-HOSTED jobs. The guard's only
#      lever is restarting SELF-HOSTED runners, and those keep working fine
#      through a lockout — the two are independent, so standing the guard down
#      buys nothing and costs every real fault it would otherwise heal.
#   2. THE EVIDENCE CAN BE STALE BY DESIGN. `probeBillingLockout` scans for the
#      most recent FAILED run within a 7-DAY lookback, so one old failure keeps
#      the verdict alive after everything since has gone green. Observed exactly
#      that: doctor reported billing-lockout while Semgrep and gitleaks were
#      passing on the self-hosted fleet. As an UNHEALABLE rung that would have
#      disabled the guard for up to a week on stale evidence.
# A stand-down rung must be a CURRENT, HOST-SCOPED fact. host-hardware,
# netstack-dead, guest-disk-corrupt and machine-crashed all are; billing is not.
UNHEALABLE_RUNGS="host-hardware netstack-dead guest-disk-corrupt machine-crashed guest-binaries-missing"

# Echo the unhealable rung doctor found, if any, as three TAB-separated fields:
#   <rung>\t<subject>\t<next_action>
# Non-zero when doctor is unavailable, healthy, or reports only rungs the guard
# CAN heal.
#
# SUBJECT is carried because one caller now acts DESTRUCTIVELY on it
# (guest-disk-corrupt -> umbra rebuild). A destructive action must name its
# target from the evidence that convicted it, never from configuration: a
# verdict about some other machine must not destroy this one. doctor leaves
# subject empty for host-wide rungs, which simply never match.
doctor_unhealable_rung() {
  command -v umbra >/dev/null 2>&1 || return 1
  _ut 15 umbra doctor --help >/dev/null 2>&1 || return 1   # pre-0.8.0 binary
  local out
  out=$(_ut "$UMBRA_TIMEOUT_DOCTOR" umbra doctor --json 2>/dev/null) || true    # exit 1 just means "faults found"
  if [ -z "$out" ]; then
    # Subshell: flag it through a file so the caller can log it. An empty
    # doctor is "not evaluated", which must be visible, never read as healthy.
    [ -n "${DOCTOR_JSON_FILE:-}" ] && : > "${DOCTOR_JSON_FILE}.empty" 2>/dev/null
    return 1
  fi
  # Called in $(…), so a variable would not survive: hand the report to
  # doctor_attention_rung through a file instead of running doctor twice.
  [ -n "${DOCTOR_JSON_FILE:-}" ] && printf '%s' "$out" > "$DOCTOR_JSON_FILE" 2>/dev/null

  printf '%s' "$out" | UNHEALABLE="$UNHEALABLE_RUNGS" python3 -c "
import sys, json, os
try:
    blocking = set(os.environ['UNHEALABLE'].split())
    for v in json.load(sys.stdin).get('verdicts', []):
        # Only 'fail' blocks healing. 'unknown' means the probe could not run,
        # which is not evidence of anything — never treat it as a diagnosis.
        if v.get('health') == 'fail' and v.get('rung') in blocking:
            print('%s\t%s\t%s' % (v.get('rung',''), v.get('subject',''), v.get('next_action','')))
            sys.exit(0)
    sys.exit(1)
except Exception:
    sys.exit(1)
" 2>/dev/null
}

# ATTENTION rungs: a real fault on a guest the guard must NOT act on, because the
# remedy is local and a reboot/rebuild is not it — so page with doctor's
# next_action and carry on healing as normal.
#
# guest-crash-damage (umbra doctor, 2026-10-16): after a guest kernel crash a
# runner tool-cache node died with SIGILL (every job on that runner failed in
# ~13s at Setup Node.js) and dmesg carried EXT4 warnings, while every runner
# showed ONLINE. Fix: clear that _tool/node/<ver>; schedule an fsck.
ATTENTION_RUNGS="guest-crash-damage"

# Echo "<rung>	<subject>	<next_action>" for the first ATTENTION verdict about
# machine $1 in the report doctor_unhealable_rung cached; non-zero when none.
doctor_attention_rung() {
  [ -s "${DOCTOR_JSON_FILE:-}" ] || return 1
  ATTN="$ATTENTION_RUNGS" SUBJ="$1" python3 -c "
import sys, json, os
try:
    want = set(os.environ['ATTN'].split())
    for v in json.load(open(sys.argv[1])).get('verdicts', []):
        if v.get('health') == 'fail' and v.get('rung') in want and v.get('subject') == os.environ['SUBJ']:
            print('%s\t%s\t%s' % (v.get('rung',''), v.get('subject',''), v.get('next_action','')))
            sys.exit(0)
    sys.exit(1)
except Exception:
    sys.exit(1)
" "$DOCTOR_JSON_FILE" 2>/dev/null
}

# Count of ACTIVE actions.runner systemd units inside the Umbra VM. The VM can be
# running while runner units are dead (oom-kill under a heavy build — observed
# 2026-07-12, umbra-ci2 primary killed Result=oom-kill). The in-VM probe is the
# STRONGER liveness signal: a unit can be dead while GitHub still lists the
# runner. (It is NOT the only one — the runners are REPO-scoped and do show up
# in repo /actions/runners; verified 2026-08-03. An earlier comment here claimed
# they were org-scoped and therefore invisible, and the per-repo loop below used
# that to dismiss a genuine outage as an API blind spot.) CAUTION: `umbra shell` fails (exit 255) when the VM is busy
# running a heavy job — treating that as "0 active" would restart runners
# mid-job. So retry, and echo -1 (UNKNOWN, do NOT heal) if the probe never
# returns a clean integer; a real count (0..N) only on a confirmed reading.
umbra_active_runners() {
  local um="${RUNNER_UMBRA_MACHINE:-$OS_VM}" out _t
  command -v umbra >/dev/null 2>&1 || { echo -1; return; }
  # HEALTHY means active/running AND STABLE, not "active right now".
  #
  # 2026-08-19 and again 2026-08-22 this guard reported "1/1 runner services
  # active on $OS_VM — healthy" while EVERY runner unit was crash-looping and
  # all CI had been queueing for two days. `--state=active | wc -l` is a single
  # sample, and a unit with Restart=always oscillates
  # activating -> active(running) -> exit 1 -> auto-restart, so a sample lands on
  # "active" often enough to look fine. The runners were failing GitHub auth
  # because the VM clock had drifted; the guard could not see it because it was
  # measuring the wrong thing.
  #
  # So: take NRestarts twice, ~7s apart, and count a unit only if it is
  # active/running in BOTH samples with an UNCHANGED restart counter. A
  # crash-looping unit always moves NRestarts within that window.
  local probe="$FOCUS_PFX"'for u in $(systemctl list-units "actions.runner.*" --no-legend --all --plain | awk "{print \$1}" | grep -E "$FRE"); do
      a1=$(systemctl show "$u" -p ActiveState --value); s1=$(systemctl show "$u" -p SubState --value); n1=$(systemctl show "$u" -p NRestarts --value)
      echo "$u|$a1|$s1|$n1"
    done > /tmp/.runner_probe_1
    sleep 7
    ok=0
    while IFS="|" read -r u a1 s1 n1; do
      a2=$(systemctl show "$u" -p ActiveState --value); s2=$(systemctl show "$u" -p SubState --value); n2=$(systemctl show "$u" -p NRestarts --value)
      if [ "$a1" = "active" ] && [ "$a2" = "active" ] && [ "$s1" = "running" ] && [ "$s2" = "running" ] && [ "$n1" = "$n2" ]; then ok=$((ok+1)); fi
    done < /tmp/.runner_probe_1
    rm -f /tmp/.runner_probe_1
    echo "$ok"'
  for _t in 1 2 3; do
    out=$(_ut "$UMBRA_TIMEOUT" umbra shell "$um" -- "$probe" 2>/dev/null)
    if [ $? -eq 0 ] && printf '%s' "$out" | grep -qE '^[[:space:]]*[0-9]+[[:space:]]*$'; then
      printf '%s' "$out" | tr -cd '0-9'; echo; return
    fi
    sleep 3
  done
  echo -1
}

# Count of INSTALLED actions.runner units in the VM — the denominator for health.
#
# This used to be the constant 1 (RUNNER_INSTANCE_COUNT default), so the guard
# printed "18/1 runner services active — healthy" once the fleet grew past one
# instance, and — worse — `fleet_active -lt EXPECTED_RUNNERS` could never fire
# while a single unit survived. Seventeen dead runners and one live one read as
# healthy. Derive it from what is actually installed, so a unit that stops
# being stable is a shortfall against the units that exist.
#
# Echoes -1 (UNKNOWN, do NOT heal) on a failed probe, same contract as
# umbra_active_runners.
umbra_installed_runners() {
  local um="${RUNNER_UMBRA_MACHINE:-$OS_VM}" out _t
  command -v umbra >/dev/null 2>&1 || { echo -1; return; }
  for _t in 1 2; do
    out=$(_ut "$UMBRA_TIMEOUT" umbra shell "$um" -- "${FOCUS_PFX}"'systemctl list-units "actions.runner.*" --no-legend --all --plain 2>/dev/null | awk "{print \$1}" | sort -u | grep -E "$FRE" | wc -l' 2>/dev/null)
    if [ $? -eq 0 ] && printf '%s' "$out" | grep -qE '^[[:space:]]*[0-9]+[[:space:]]*$'; then
      printf '%s' "$out" | tr -cd '0-9'; echo; return
    fi
    sleep 3
  done
  echo -1
}

# Restart dead runner services inside the Umbra VM (oom-kill recovery). Returns
# the post-heal active count via umbra_active_runners.
# Restart ONLY the runner units that are not active. `systemctl restart
# "actions.runner.*"` used to restart EVERY runner: one oom-killed listener took
# down every in-flight job on the other 19 (2026-10-07 09:38 — three PRs across
# two repos lost their runs at once). A healthy busy runner must never be
# restarted by a heal. Kept in a variable so the test can run it against a stub.
HEAL_UMBRA_CMD='for u in $(systemctl list-units "actions.runner.*" --all --no-legend --plain 2>/dev/null | awk "{ if (\$3 != \"active\") print \$1 }" | grep -E "$FRE"); do sudo systemctl reset-failed "$u" 2>/dev/null; sudo systemctl restart "$u" 2>/dev/null; done'
heal_umbra_runners() {
  local um="${RUNNER_UMBRA_MACHINE:-$OS_VM}"
  # Unreadable focus file: heal nothing (see FOCUS_BROKEN above), report the count.
  [ "$FOCUS_BROKEN" -eq 1 ] && { umbra_active_runners; return; }
  hands_off "$um" "runner restart" && { umbra_active_runners; return; }
  _ut "$UMBRA_TIMEOUT_SLOW" umbra shell "$um" -- "${FOCUS_PFX}${HEAL_UMBRA_CMD}" >/dev/null 2>&1
  sleep 6

  # A restart cannot fix a runner whose registration GitHub has DELETED — the
  # listener exits "no retry needed" and the service goes straight back to dead.
  # That is what happened on 2026-08-02 and again on 2026-08-04: clock drift after
  # a VM resume expired the auth tokens, GitHub dropped all nine registrations, and
  # this guard kept "healing" by restarting services that could never come back.
  # Re-registration is the only recovery, so escalate to it when the restart did
  # not take.
  local active; active="$(umbra_active_runners)"
  if [ "${active:-0}" -eq 0 ] 2>/dev/null; then
    local rr="$(dirname "$0")/runner-reregister.sh"
    [ -x "$rr" ] || rr="$HOME/.claude/scripts/runner-reregister.sh"
    if [ -x "$rr" ]; then
      echo "  restart left 0 active runners — escalating to re-registration"
      _ut "$((UMBRA_TIMEOUT_SLOW * 4))" "$rr" >/dev/null 2>&1
      sleep 6
    fi
  fi

  umbra_active_runners
}

# Is ANY self-hosted runner online across the CI repos? A BUSY runner still
# reports online to GitHub, so this is the authoritative "the guest is alive and
# serving" signal — the discriminator between a merely-busy guest and a hung one.
any_runner_online() {
  local r
  for r in "${REPOS[@]}"; do runner_online "$GH_USER/$r" && return 0; done
  return 1
}

# Hard-reboot the guest VM (stop + start). Use ONLY for a HUNG guest: the VM
# shows running but SSH is unreachable AND no runner reports online to GitHub.
# A service restart (heal_umbra_runners) needs SSH, so it cannot recover a
# wedged guest — only a reboot can. Root cause of the ~3h CI stall on
# 2026-07-17: umbra-ci5's OS hung (`Connection reset by peer`), runner OFFLINE,
# and the guard misread SSH-dead as "busy" and never rebooted. Returns 0 when a
# runner is back online after the reboot.
reboot_guest() {
  local um="${RUNNER_UMBRA_MACHINE:-$OS_VM}" _i
  hands_off "$um" "guest reboot" && return 1
  _ut "$UMBRA_TIMEOUT_SLOW" umbra stop "$um" >/dev/null 2>&1 || true
  sleep 4
  # shellcheck disable=SC2046  # intentional: empty flag list must vanish, not become an empty argument
  _ut "$UMBRA_TIMEOUT_SLOW" umbra start $(umbra_start_flags umbra) "$um" >/dev/null 2>&1 || return 1
  for _i in 1 2 3 4 5 6 7 8; do
    sleep 15
    any_runner_online && return 0
  done
  return 1
}

# ── auto-rebuild a guest whose ROOT FILESYSTEM is corrupt ────────────────────
# Authorised by Ahmad on 2026-09-16: "rebuild it if it comes back".
#
# $OS_VM corrupted TWICE in two days — ext4 tripping its error flag and
# remounting root read-only. It surfaces as unrelated breakage (a missing
# libpsl.so.5, a listener log frozen mid-write, a systemctl restart that does
# nothing, runners draining 20->16 while jobs queue unrun), and a REBOOT does
# not fix it: the stop is forced at 120s, readiness fails, and the vm process
# burns 0.01s of cpu over a 10s sample. A rebuild fixed it in 8m35s, restoring
# 20 runners on a fresh disk reading CLEAN error_count=0.
#
# This is the guard's ONLY destructive remedy: the rebuild runs an rm of the
# machine directory, and every snapshot lives inside it. Hence the guardrails
# in lib/guest-rebuild.sh and the busy rule below.
#
# NOTE guest-disk-corrupt deliberately STAYS in UNHEALABLE_RUNGS: restarting
# such a guest still makes it worse. This remedy is layered in FRONT of the
# stand-down, not a reclassification of the rung.
UMBRA_TIMEOUT_REBUILD="${UMBRA_TIMEOUT_REBUILD:-2400}"   # the measured rebuild took 8m35s
GUEST_REBUILD_SETTLE="${GUEST_REBUILD_SETTLE:-15}"       # settle before verifying

# Is the guest usable RIGHT NOW — does ssh answer, and is root WRITABLE?
#
# Root-writable is the discriminator that matters for this fault: errors=remount-ro
# is exactly what a corrupt ext4 does, so a guest can answer ssh while being
# unable to run a single job. The probe writes to / itself, never to /tmp or
# /run — those are tmpfs and stay writable on a read-only root, which is how a
# NUL-filled file in /run once got mistaken for disk corruption.
guest_usable() {
  local um="$1" out
  out=$(printf '(sudo touch /.guard-rwtest 2>/dev/null && sudo rm -f /.guard-rwtest && echo RW) || echo RO\n' \
    | _ut "$UMBRA_TIMEOUT" umbra shell "$um" -- bash 2>/dev/null | tr -d '\r' | tail -1)
  [ "$out" = "RW" ]
}

# Is ANY self-hosted runner currently marked busy across the CI repos?
any_runner_busy() {
  local r out
  for r in "${REPOS[@]}"; do
    out=$(gh api "repos/$GH_USER/$r/actions/runners" 2>/dev/null) || continue
    if printf '%s' "$out" | python3 -c "
import sys, json
try:
    rs = json.load(sys.stdin).get('runners', [])
    sys.exit(0 if any(x.get('busy') for x in rs) else 1)
except Exception:
    sys.exit(1)" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

# Set when a rebuild's verification fails; blocks further automatic rebuilds
# until a human removes it. Overridable for tests.
REBUILD_BLOCK_FILE="${REBUILD_BLOCK_FILE:-$HOME/.whisky-os-state/umbra-rebuild-blocked}"

# guest_kernel_docker_ok <machine>: the guest runs the NEWEST installed kernel
# (same expression as umbra's cloudinit.NewestKernelCmd) AND docker is active.
guest_kernel_docker_ok() {
  local um="${1:?}" out
  out=$(_ut "$UMBRA_TIMEOUT" umbra shell "$um" -- 'n=$(ls /boot/vmlinuz-* 2>/dev/null | sed "s#^/boot/vmlinuz-##" | grep -Ev "[.]dpkg-[a-z]+$" | sort -V | tail -n1); if [ -n "$n" ] && [ "$(uname -r)" = "$n" ] && [ "$(systemctl is-active docker 2>/dev/null)" = active ]; then echo KDOK; fi' 2>/dev/null)
  printf '%s' "$out" | grep -q '^KDOK$'
}

# rebuild_corrupt_guest <machine> <doctor next_action> [rung]
#
# The guard's one destructive remedy, shared by every doctor rung whose only
# real fix is recreating the guest. Written for guest-disk-corrupt; extended
# 2026-09-22 to guest-binaries-missing (dpkg's own database says packages are
# installed whose files are gone — the exact fault that froze CI fleet-wide
# that day, across all 15 repos this guest serves: see
# docs/plans/2026-09-22-throttle-hardening.md). [rung] defaults to
# guest-disk-corrupt for callers that predate this parameter.
#
# EVERY guardrail below — the busy rule, the cooldown, the rate limit, the
# post-rebuild verification — is IDENTICAL for both rungs, unchanged. See the
# plan doc's Ruling on why the busy rule specifically is not weakened for
# guest-binaries-missing, despite a broken throttle hook being able to make a
# runner look busy for longer than a real job would.
rebuild_corrupt_guest() {
  local um="$1" d_next="$2" rung="${3:-guest-disk-corrupt}"
  local usable="no" busy="no" decision hist rc probs="" active state now
  local fault_now fault_was
  case "$rung" in
    guest-binaries-missing)
      fault_now="has MISSING BINARIES (doctor rung guest-binaries-missing — dpkg reports packages installed whose files are gone from disk)"
      fault_was="had MISSING BINARIES (dpkg database vs. disk; doctor rung guest-binaries-missing)"
      ;;
    *)
      fault_now="root filesystem is CORRUPT (doctor rung guest-disk-corrupt)"
      fault_was="root filesystem was CORRUPT (ext4 error flag; doctor rung guest-disk-corrupt)"
      ;;
  esac
  now="$(date -u +%s)"
  guest_usable "$um" && usable="yes"
  any_runner_busy && busy="yes"
  hist="$(guest_rebuild_history "$um")"

  # Every decision is logged WITH its evidence, so a human can audit why a
  # destructive action did or did not happen.
  echo "[ci-runner-guard] ${rung} on ${um}: doctor health=fail subject=${um}; guest_usable=${usable}; runner_busy=${busy}; rebuild_history=[${hist}]"

  # THE BUSY RULE. A busy runner blocks the rebuild only while the guest is
  # still USABLE — then it is plausibly a real job. On an unusable guest the
  # busy flag is a STALE REGISTRATION, not work in flight: on 2026-09-16
  # runners drained 20->16 while jobs queued unrun and a listener log sat
  # frozen mid-write. Deferring to that flag would defer forever, which is the
  # failure this change exists to end.
  if [ "$busy" = "yes" ] && [ "$usable" = "yes" ]; then
    FLEET_UP=0
    flipped "runner fleet: ${um} ${fault_now} and an automatic rebuild is authorised, but a self-hosted runner is BUSY and the guest still answers with a writable root — DEFERRING the rebuild one cycle rather than destroying a live CI job. Re-checked next cycle. If it persists: ${d_next}"
    return 0
  fi

  # A rebuild whose post-verification FAILED blocks every further automatic
  # rebuild until a human clears the marker (2026-11-02: image-kernel rebuild
  # loop — each rebuild produced a guest that could not run docker, and the
  # next cycle rebuilt it again). Repeating the remedy is not a new attempt.
  if [ -f "$REBUILD_BLOCK_FILE" ]; then
    flipped "runner fleet: ${um} ${fault_now} but automatic rebuilds are BLOCKED — the last rebuild did not verify ($(head -1 "$REBUILD_BLOCK_FILE")). NOT rebuilding. Fix the cause, then rm $REBUILD_BLOCK_FILE."
    return
  fi
  decision="$(guest_rebuild_allowed "$um" "$now")"
  case "$decision" in
    cooldown:*)
      FLEET_UP=0
      flipped "runner fleet: ${um} ${fault_now} but it was auto-rebuilt too recently — ${decision#cooldown:}s of the ${GUEST_REBUILD_MIN_GAP_SEC}s cooldown remain, so NOT rebuilding. A guest that re-faults this fast is not being fixed by rebuilding: suspect the host or the guest kernel. Rebuild history: [${hist}]."
      return 0
      ;;
    limit:*)
      FLEET_UP=0
      flipped "runner fleet: ${um} ${fault_now} and has ALREADY been auto-rebuilt ${decision#limit:} time(s) inside the last $((GUEST_REBUILD_WINDOW_SEC / 3600))h (max ${GUEST_REBUILD_MAX}) — NOT rebuilding again. Rebuilding is not fixing the cause, and this needs Ahmad. Rebuild history: [${hist}]. Doctor's next action: ${d_next}"
      return 0
      ;;
  esac

  # A rebuild that started after the pre-flight (umbra's own, or a human's)
  # must never get a second one on top of it.
  if hands_off "$um" "automatic rebuild"; then
    note "runner fleet: ${um} ${fault_now}, but umbra rebuild is already provisioning it — not rebuilding on top ($(umbra_provisioning "$um"))"
    return 0
  fi
  # Record BEFORE the attempt, deliberately: an attempt that hangs or dies still
  # spends budget. Recording afterwards would let a crashing rebuild loop.
  guest_rebuild_record "$um" "$now"
  echo "[ci-runner-guard] REBUILDING ${um} — authorised remedy for ${rung} (history was [${hist}])"
  _ut "$UMBRA_TIMEOUT_REBUILD" umbra rebuild "$um" --yes >/dev/null 2>&1
  rc=$?
  sleep "$GUEST_REBUILD_SETTLE"

  # VERIFY — an exit code of 0 is not a restored service.
  local problems=()
  [ "$rc" -eq 0 ] || problems+=("the rebuild exited ${rc}")
  state="$(umbra_vm_settled_state)"
  [ "$state" = "running" ] || problems+=("machine state is '${state:-unlisted}', not running")
  guest_usable "$um" || problems+=("ssh/root-writable probe failed — ssh dead or root STILL read-only")
  active="$(umbra_active_runners)"
  [ "${active:-0}" -ge 1 ] 2>/dev/null || problems+=("no runner units active in the guest (probe returned ${active})")
  any_runner_online || problems+=("GitHub lists no online runner for any CI repo")
  guest_kernel_docker_ok "$um" || problems+=("guest is not on its newest (HWE) kernel with docker active — the image kernel oopses on its first container")

  if [ ${#problems[@]} -eq 0 ]; then
    FLEET_UP=1
    flipped "runner fleet: ${um} ${fault_was} — REBUILT automatically and service is RESTORED: state running, ssh answering, root writable, ${active} runner unit(s) active, GitHub runners online."
  else
    FLEET_UP=0
    printf '%s %s\n' "$(date -u +%FT%TZ)" "post-rebuild verification failed: ${problems[*]}" > "$REBUILD_BLOCK_FILE" 2>/dev/null || true
    probs="$(printf '%s; ' ${problems[@]+"${problems[@]}"})"
    flipped "runner fleet: ${um} ${fault_was} and the automatic rebuild did NOT restore service — ${probs}Investigate before the next cycle (doctor's advice was: ${d_next})."
  fi
}

# Self-heal the Umbra runner fleet: boot the VM if it's stopped, or restart the
# runner services if the VM is up but they're dead (oom-kill). OrbStack was
# retired 2026-07-12 (VM deleted, app uninstalled) so there is no orb fallback.
try_runner_heal() {
  local slug="$1" _i started=""
  local um="${RUNNER_UMBRA_MACHINE:-$OS_VM}"
  hands_off "$um" "runner heal" && return 1
  if command -v umbra >/dev/null 2>&1 && _ut "$UMBRA_TIMEOUT" umbra list 2>/dev/null | grep -qE "^${um}[[:space:]]+stopped"; then
    # shellcheck disable=SC2046  # intentional: empty flag list must vanish, not become an empty argument
    _ut "$UMBRA_TIMEOUT_SLOW" umbra start $(umbra_start_flags umbra) "$um" >/dev/null 2>&1 || true
    started="umbra-vm:$um"
  elif umbra_fleet_running && [ "$(umbra_active_runners)" = "0" ]; then
    # VM up but all runner services dead (oom-kill) — restart them in place.
    heal_umbra_runners >/dev/null
    started="umbra-svc:$um"
  fi
  [ -n "$started" ] || return 1
  for _i in 1 2 3 4 5 6; do sleep 20; runner_online "$slug" && return 0; done
  # Umbra runners are org-registered — invisible to the repo API — so judge by
  # the queue instead: if CI isn't backed up, the heal worked.
  umbra_fleet_running && ! ci_queue_backed_up "$slug" && return 0
  return 1
}

# Are ALL self-hosted runners busy for this repo? Returns 0 only when >=1 runner exists
# and every runner has busy=true (the saturation condition).
all_runners_busy() {
  local slug="$1"
  local out; out=$(gh api "repos/$slug/actions/runners" 2>/dev/null) || return 1
  printf '%s' "$out" | python3 -c "
import sys, json
try:
    runners = json.load(sys.stdin).get('runners', [])
    # Only count self-hosted (non-ephemeral GitHub-hosted have runner_type='read_only')
    sh = [r for r in runners if r.get('runner_type','') != 'read_only']
    if not sh:
        sys.exit(1)  # no self-hosted runners at all
    sys.exit(0 if all(r.get('busy') for r in sh) else 1)
except Exception:
    sys.exit(1)
" 2>/dev/null
}

# Are CI jobs stuck queued or recently-cancelled beyond the threshold?
# Returns 0 (queue backed up) if >=1 run is found older than SATURATION_QUEUE_MIN.
ci_queue_backed_up() {
  local slug="$1"
  local threshold_min="$SATURATION_QUEUE_MIN"
  local now_epoch; now_epoch=$(date +%s)
  local threshold_sec=$(( threshold_min * 60 ))

  local runs; runs=$(gh run list --repo "$slug" --workflow CI --limit 10 \
    --json databaseId,status,conclusion,createdAt 2>/dev/null) || return 1

  printf '%s' "$runs" | python3 -c "
import sys, json
try:
    from datetime import datetime
    data = json.load(sys.stdin)
    now_epoch = $now_epoch
    threshold_sec = $threshold_sec

    for r in data:
        # Stuck queued jobs
        if r.get('status') == 'queued':
            try:
                dt = datetime.fromisoformat(r.get('createdAt','').replace('Z','+00:00'))
                if (now_epoch - dt.timestamp()) > threshold_sec:
                    sys.exit(0)
            except Exception:
                pass
        # Recently-cancelled jobs with no real step failure = saturation cancellation
        if r.get('status') == 'completed' and r.get('conclusion') == 'cancelled':
            try:
                dt = datetime.fromisoformat(r.get('createdAt','').replace('Z','+00:00'))
                age = now_epoch - dt.timestamp()
                if age < threshold_sec * 4:  # only recent cancellations signal saturation
                    sys.exit(0)
            except Exception:
                pass
    sys.exit(1)
except Exception:
    sys.exit(1)
" 2>/dev/null
}

current_use_self_hosted() {
  gh variable get USE_SELF_HOSTED --repo "$1" 2>/dev/null | tr -d '[:space:]'
}

# ── HOST disk pressure ────────────────────────────────────────────────────────
# 2026-09-04: the fleet went down with $OS_VM "running" but SSH never ready and
# a 0-byte console.log. Cause: the HOST volume was at 98% — 9 GB free of 460 GB.
# A guest whose disk.img is a 64 GB sparse file cannot fault in the blocks it
# needs to boot, so it starts and never reaches sshd.
#
# Nothing caught it. This guard already measures the GUEST's disk every 30 min
# (below) but had no host reading at all — and when the guest is unreachable,
# "guest disk unreadable" was all it said, which is the one moment the host
# figure is both still measurable and the most likely explanation.
#
# The only host-disk check that existed lived in mac-maintenance.sh with a
# sensible 20 GB threshold and a WEEKLY cadence (Sunday 04:00). The disk fell
# from healthy to fleet-fatal inside that window and the next tick was days out.
# A resource CI writes gigabytes to per job cannot be watched weekly — read the
# job's own cadence (feedback-monitor-alert-measures-the-monitor).
#
# APFS note: `df /` reports the sealed system volume. Container free space is
# shared, so the AVAILABLE figure matches, but used% does not — /System/Volumes/Data
# is the honest read. Falls back to / where that path does not exist.
HOST_DISK_WARN_PCT=${HOST_DISK_WARN_PCT:-88}
HOST_DISK_CRIT_PCT=${HOST_DISK_CRIT_PCT:-94}
HOST_VOL="/System/Volumes/Data"; [ -d "$HOST_VOL" ] || HOST_VOL="/"

host_disk_used=$(host_disk_used_pct "$HOST_VOL")
host_disk_free_g=$(host_disk_free_gb "$HOST_VOL")
# Unreadable is UNKNOWN, never ok — same rule as the guest reading.
host_disk_level="$(disk_pressure_level "$host_disk_used" "$HOST_DISK_WARN_PCT" "$HOST_DISK_CRIT_PCT")"

case "$host_disk_level" in
  unknown) note "host disk: unreadable (df on $HOST_VOL returned nothing) — cannot rule the host out as a cause" ;;
  crit)    flipped "HOST disk ${host_disk_used}% used, only ${host_disk_free_g:-?}GB free (>=${HOST_DISK_CRIT_PCT}%) — this WEDGES the guest: a sparse disk.img cannot fault in blocks it needs and the VM boots without ever reaching sshd. Free space on the Mac before touching the guest (Xcode DerivedData, npm cache, ~/.cache, Docker images)." ;;
  warn)    note "host disk: ${host_disk_used}% used, ${host_disk_free_g:-?}GB free (warn >=${HOST_DISK_WARN_PCT}%) — reclaim before it reaches ${HOST_DISK_CRIT_PCT}%" ;;
  *)       note "host disk: ${host_disk_used}% used, ${host_disk_free_g:-?}GB free — ok" ;;
esac

# ── GLOBAL: Umbra runner fleet liveness (shared across all repos) ─────────────
# The runner lives in ONE Umbra VM ($OS_VM). A running VM with a dead runner
# service (oom-kill) or a wholly HUNG guest (VM up, SSH dead) can leave the
# runner offline — so probe the systemd unit directly, heal a dead service,
# hard-reboot a hung guest, and alert on Telegram. This is the PRIMARY "runner
# down" watcher. NOTE: the current $OS_VM runners are REPO-scoped (visible in the
# repo /actions/runners API); the org-scoped blind-spot handling below is kept
# for the legacy/future org-registered setup.
# Canonical since the 2026-07-30 rebuild: ONE Umbra guest ($OS_VM) hosting the
# repo-scoped runners. umbra-ci5 and umbra-ci2 were DELETED that day — do NOT
# default to either or this whole block silently no-ops against a machine that
# does not exist. Both overridable via RUNNER_UMBRA_MACHINE / RUNNER_INSTANCE_COUNT.
# Expected = what is installed in the VM right now, not a constant. An explicit
# RUNNER_INSTANCE_COUNT still wins, so do NOT set it in the plist: until
# 2026-09-15 the plist pinned it to 1, the installed-units probe never ran, and
# the guard printed "20/1 runner services active" for a 20-runner fleet.
# When the probe returns -1 (UNKNOWN), fall back to the umbra runner manifest
# (what was declared), then to 1.
EXPECTED_RUNNERS="${RUNNER_INSTANCE_COUNT:-}"
if [ -z "$EXPECTED_RUNNERS" ]; then
  EXPECTED_RUNNERS="$(umbra_installed_runners)"
  [ "${EXPECTED_RUNNERS:-0}" -ge 1 ] 2>/dev/null || EXPECTED_RUNNERS="$(umbra_manifest_runners)"
  [ "${EXPECTED_RUNNERS:-0}" -ge 1 ] 2>/dev/null || EXPECTED_RUNNERS=1
fi
UM="${RUNNER_UMBRA_MACHINE:-$OS_VM}"
# FLEET_UP is the AUTHORITATIVE runner-liveness flag for the per-repo loop below,
# which otherwise misreads a busy/queued fleet as "runners down" (the repo API
# can't see org-registered runners). 1 = fleet is up (healthy or busy), 0 = down.
#
# FAIL CLOSED. This used to initialise to 1, so ANY path that skipped the block
# below left it asserting "fleet healthy" — and the per-repo loop then explained
# a real outage away as load/saturation. That is exactly what happened on
# 2026-08-03: `umbra` lives in /usr/local/bin, which was missing from the
# LaunchAgent PATH, so `command -v umbra` failed, the entire liveness block was
# skipped, and the guard reported healthy straight through a wedged guest.
# Unknown is not healthy — start at 0 and let the checks below prove otherwise.
FLEET_UP=0
# Pre-flight 0: is the fleet PARKED (deliberately out of service)?
#
# 2026-08-09: $OS_VM stopped booting on 08-06 and every repo was routed to cloud
# on 08-08 — but nothing told this guard, so it hard-rebooted a dead guest every
# 30 minutes for three days and Telegrammed each failure. ~30 pages about a
# runner no CI depended on. The `doctor_unhealable_rung` pre-flight below was
# built to stop exactly that thrash and did not fire, because `umbra doctor`
# classifies a non-booting guest as rung `unknown`, which is not in its
# unhealable set. Do NOT rely on doctor alone to notice a pointless heal.
#
# Parked is not blind: we skip healing and fleet alerting, but still assert the
# safety invariant — every repo must actually be on cloud. Parked fleet + a repo
# on self-hosted is the dangerous state (CI queues forever and the watcher that
# would say so is the one standing down), so that combination pages loudly.
if fleet_parked; then
  park_violations=()
  for r in "${REPOS[@]}"; do
    [ "$(current_use_self_hosted "$GH_USER/$r")" = "false" ] || park_violations+=("$r")
  done
  if [ ${#park_violations[@]} -gt 0 ]; then
    flipped "runner fleet: PARKED ($(fleet_park_reason)) but ${park_violations[*]} still has USE_SELF_HOSTED != false — CI on those repos will queue FOREVER against a runner that is out of service. Set it to false, or un-park by deleting $FLEET_PARK_FILE."
    msg="CI Runner Guard — ${#findings[@]} action(s):"$'\n'"$(printf '  • %s\n' ${findings[@]+"${findings[@]}"})"
    echo "$msg"
    "$HERE/notify.sh" "CI Runner Guard" "$msg" >/dev/null 2>&1 || true
    write_status "runner" "false" "fleet parked but ${#park_violations[@]} repo(s) still routed to self-hosted" \
      "$(printf '%s\n' ${park_violations[@]+"${park_violations[@]}"} | python3 -c 'import json,sys; print(json.dumps({"repos":[l for l in sys.stdin.read().splitlines() if l]}))')"
    exit 1
  fi
  # Healthy parked state. Report it on the dashboard rather than exiting silent —
  # a watcher that stands down without saying so is how a park becomes an outage.
  echo "[ci-runner-guard] PARKED — $(fleet_park_reason); the ${#REPOS[@]} monitored Ebda OS repos are on cloud CI (Umbra serves Ebda only). Standing down (no heal, no alert)."
  write_status "runner" "true" "fleet parked on purpose — all repos on cloud CI" \
    "$(FPR="$(fleet_park_reason)" FPF="$FLEET_PARK_FILE" python3 -c 'import json,os; print(json.dumps({"parked":True,"reason":os.environ["FPR"],"unpark":"rm "+os.environ["FPF"]}))')"
  exit 0
fi

# Pre-flight 0b: is `umbra rebuild` provisioning $UM right now?
#
# 2026-10-16 02:53: this guard rebooted a brand-new $OS_VM in the middle of a
# rebuild ("SSH dead + no runner → reboot") — from outside, a guest being
# provisioned looks exactly like a hung one, and with a doctor verdict in hand
# the guard would even start a second `umbra rebuild` on top of the first.
# umbra rebuild holds ${UMBRA_ROOT:-~/.umbra}/provisioning/<vm> (expires=<epoch>,
# refreshed per step, removed on success); lib/umbra-provisioning.sh honours
# only an unexpired, <=4h marker, so a dead rebuild hands the guest back within
# one step's TTL. Repos routed to self-hosted queue for the window — the
# expected cost of a deliberate rebuild, not an outage to page about.
#
# PER MACHINE, never the whole guard: findings already collected (a host disk at
# crit, which a rebuild allocating a fresh disk.img makes worse), the fleet-wide
# clock/disk/orphan checks and the per-repo routing all still run. Only $UM's
# liveness/heal/reboot/rebuild is skipped, and every guest-changing action
# re-checks the marker right before it acts (hands_off).
PROVISIONING=0; PROV_REASON=""
if PROV_REASON="$(umbra_provisioning "$UM")"; then
  PROVISIONING=1
  echo "[ci-runner-guard] PROVISIONING — $UM: $PROV_REASON. Standing down for $UM only (no heal, reboot, rebuild or outage page for it)."
  note "runner fleet: $UM — $PROV_REASON; guard hands-off this machine"
fi

# Pre-flight: ask umbra doctor whether this fault is even healable. If the host
# hardware is faulting, the netstack is dead, or GitHub is refusing to start
# jobs, then starting/rebooting/restarting anything is pure thrash — and doing
# it every 30 minutes on a degrading host is worse than doing nothing. Alert
# with the real next action and skip healing this cycle.
DOCTOR_JSON_FILE="$(mktemp "${TMPDIR:-/tmp}/ci-runner-guard-doctor.XXXXXX" 2>/dev/null || true)"
[ -n "$DOCTOR_JSON_FILE" ] && trap 'rm -f "$DOCTOR_JSON_FILE" "$DOCTOR_JSON_FILE.empty"' EXIT
DOCTOR_BLOCK=""
# A provisioning guest gives meaningless verdicts and its rebuild runs its own
# health step, so doctor is not consulted about it.
[ "$PROVISIONING" -eq 1 ] || DOCTOR_BLOCK="$(doctor_unhealable_rung || true)"
if [ -n "$DOCTOR_JSON_FILE" ] && [ -e "$DOCTOR_JSON_FILE.empty" ]; then
  echo "[ci-runner-guard] umbra doctor returned nothing within ${UMBRA_TIMEOUT_DOCTOR}s"
  note "umbra doctor returned nothing within ${UMBRA_TIMEOUT_DOCTOR}s — the unhealable pre-flight and attention rungs were NOT evaluated this cycle (raise UMBRA_TIMEOUT_DOCTOR, or check: time umbra doctor --json)"
fi
if [ "$PROVISIONING" -eq 0 ] && DOCTOR_ATTN="$(doctor_attention_rung "$UM")"; then
  flipped "runner fleet: umbra doctor reports '$(printf '%s' "$DOCTOR_ATTN" | cut -f1)' on $UM — the guest is up but carries damage a restart does not fix, so the guard is NOT acting on it. Next action: $(printf '%s' "$DOCTOR_ATTN" | cut -f3-)"
fi
if [ "$PROVISIONING" -eq 1 ]; then
  # $UM is being provisioned: no liveness verdict, heal or page for it.
  FLEET_UP=0
elif [ -n "$DOCTOR_BLOCK" ]; then
  d_rung="$(printf '%s' "$DOCTOR_BLOCK" | cut -f1)"
  d_subject="$(printf '%s' "$DOCTOR_BLOCK" | cut -f2)"
  d_next="$(printf '%s' "$DOCTOR_BLOCK" | cut -f3-)"
  if { [ "$d_rung" = "guest-disk-corrupt" ] || [ "$d_rung" = "guest-binaries-missing" ]; } \
      && [ -n "$d_subject" ] && [ "$d_subject" = "$UM" ]; then
    # The two rungs the guard may now act on DESTRUCTIVELY — and only for the
    # machine the verdict itself names. A verdict about some other guest falls
    # through to the stand-down below rather than destroying ours.
    rebuild_corrupt_guest "$UM" "$d_next" "$d_rung"
  else
    FLEET_UP=0
    flipped "runner fleet: umbra doctor reports '$d_rung'${d_subject:+ (subject: $d_subject)} — NOT healable by restarting, so the guard is standing down this cycle. Next action: $d_next"
  fi
elif command -v umbra >/dev/null 2>&1; then
  # Read the state ONCE, and let an in-flight stop/start finish before judging it
  # (umbra_vm_settled_state explains the 2026-09-15 false page).
  vm_state0="$(umbra_vm_state)"; vm_state="$vm_state0"
  case "$vm_state0" in starting|stopping) vm_state="$(umbra_vm_settled_state)" ;; esac
  if [ "$vm_state" != "running" ]; then
    if [ "$vm_state" = "stopped" ] && hands_off "$UM" "umbra start"; then
      FLEET_UP=0
      note "runner fleet: $UM stopped while umbra rebuild provisions it — not starting it"
    elif [ "$vm_state" = "stopped" ]; then
      # shellcheck disable=SC2046  # intentional: empty flag list must vanish, not become an empty argument
      _ut "$UMBRA_TIMEOUT_SLOW" umbra start $(umbra_start_flags umbra) "$UM" >/dev/null 2>&1 || true; sleep 8
      # Claim a heal only when the VM really is running — this used to print
      # SELF-HEALED whatever `umbra start` did.
      vm_state="$(umbra_vm_settled_state)"
      if [ "$vm_state" = "running" ]; then
        FLEET_UP=1
        flipped "runner fleet: Umbra VM '$UM' was STOPPED — SELF-HEALED (umbra start); active runners now $(umbra_active_runners)/$EXPECTED_RUNNERS."
      else
        FLEET_UP=0
        flipped "runner fleet: Umbra VM '$UM' was STOPPED and 'umbra start' did NOT bring it up (state now '${vm_state:-unlisted}') — CI cannot run. Check: umbra list, ~/.umbra/log/umbrad.err.log."
      fi
    elif [ "$vm_state" = "starting" ] || [ "$vm_state" = "stopping" ]; then
      FLEET_UP=0
      flipped "runner fleet: Umbra VM '$UM' has been '$vm_state' for over ${UMBRA_TIMEOUT_SLOW}s — the lifecycle operation is stuck and CI cannot run. Check: umbra list; a stop that never confirms leaves the machine crashed (umbra stop $UM again, then start)."
    else
      FLEET_UP=0
      flipped "runner fleet: Umbra VM '$UM' is NOT running and not startable (state: '${vm_state:-unlisted/unreachable}') — CI cannot run. Check: umbra list / umbra start $UM."
    fi
  elif [ "$vm_state0" != "running" ]; then
    # It was mid-transition and has settled to running: somebody restarted it. The
    # guest is still booting — units activating, maybe no sshd yet — so the probes
    # below would read 0 or UNKNOWN and restart or REBOOT a VM a human just brought
    # up. Stand off for one cycle; the next run measures a booted guest.
    FLEET_UP=1
    note "runner fleet: $UM was '$vm_state0' when checked (a planned stop/start?) and has settled to running — not probing a still-booting guest this cycle; the next run re-checks."
  else
    fleet_active="$(umbra_active_runners)"
    if [ "$fleet_active" -lt 0 ]; then
      # Probe failed after retries — VM is up (umbra_fleet_running) but SSH didn't
      # answer. Two very different causes, disambiguated by the GitHub runner status:
      #   (a) BUSY — the guest is running a heavy job and SSH is refused under load.
      #       A busy runner still reports ONLINE. Do NOT touch it (a restart/reboot
      #       would kill the running job).
      #   (b) HUNG — the guest OS is wedged (VM running, SSH `Connection reset`).
      #       The runner then reports OFFLINE. A service restart needs SSH, so it
      #       cannot recover it; only a guest reboot can. This is the 2026-07-17
      #       ~3h-stall gap: SSH-dead was blanket-treated as "busy" and never rebooted.
      if any_runner_online; then
        note "runner fleet: $UM is up but SSH is unreachable while a runner still reports ONLINE — busy with a heavy job; not healing."
      elif hands_off "$UM" "guest reboot"; then
        FLEET_UP=0
        note "runner fleet: $UM looks hung, but umbra rebuild just started provisioning it — not rebooting"
      elif reboot_guest; then
        flipped "runner fleet: $UM was HUNG (VM running, SSH dead, runner OFFLINE) — SELF-HEALED via guest reboot (umbra stop/start); runner back online."
      else
        # Name the host FIRST when it is critical. A guest that boots and never
        # reaches sshd on a 94%-full host is almost always the host, and sending
        # someone into `umbra shell` on an unreachable guest wastes the hour.
        # Distinguish "the guest is not EXECUTING" from "it booted and ssh died".
        # They read identically from outside — both give a dead port 22 — but they
        # have different fixes, and sending someone into `umbra shell` on a guest
        # that never ran wastes the hour. The tell is the console: a guest that
        # boots emits firmware output within seconds, so 0 bytes plus an idle vm
        # process means nothing is running inside it.
        #
        # 2026-09-06: $OS_VM sat at 0 bytes of console with the Virtualization XPC
        # process at 0.0% CPU and 0.8GB resident against 6GiB configured, on a host
        # with 52GB free. It had been diagnosed for days as a macOS-update
        # networking fault and as "sshd not ready" — both describe a boot that was
        # not happening. Note the vm runs as an Apple XPC service parented to
        # launchd, NOT as a child of umbrad, and the name is capitalised; a
        # lowercase or child-of-umbrad search finds nothing and invites the wrong
        # conclusion that no vm exists at all.
        _console="${HOME}/.umbra/machines/${UM}/console.log"
        _csize=0
        [ -f "$_console" ] && _csize="$(wc -c < "$_console" 2>/dev/null | tr -d " ")"
        _vmcpu="$(ps -eo %cpu,comm 2>/dev/null | awk '/Virtualization.VirtualMachine/{c+=$1} END{printf "%.0f", c+0}')"
        if [ "${_csize:-0}" -eq 0 ] && [ "${_vmcpu:-0}" -eq 0 ]; then
          flipped "runner fleet: $UM is NOT EXECUTING — console.log is 0 bytes and the Virtualization process is idle at ${_vmcpu:-0}% cpu, so the vm is instantiated but nothing is running inside it. This is NOT an ssh, networking or runner-service fault: umbra shell and systemctl cannot reach a guest that never booted. Host disk is ${host_disk_used:-?}% used, so the host is not the cause either. Suspect the guest image itself (a corrupt or unreadable disk.img boots to a silent console); check ~/.umbra/log/umbrad.err.log for a boot refusal."
        elif [ "${host_disk_level:-}" = "crit" ]; then
          flipped "runner fleet: $UM appears HUNG (SSH dead + no runner online) and a reboot did NOT recover it — the HOST disk is ${host_disk_used}% used (${host_disk_free_g:-?}GB free), which is the likely cause: free host space, THEN umbra stop/start $UM. A 0-byte console.log confirms the guest never got far enough to emit boot output."
        else
          flipped "runner fleet: $UM appears HUNG (SSH dead + no runner online) and a guest reboot did NOT recover it — investigate: umbra stop $UM && umbra start $UM, then umbra shell $UM -- systemctl status 'actions.runner.*'. Host disk is ${host_disk_used:-?}% used, so the host is not the cause."
        fi
      fi
    elif [ "$fleet_active" -lt "$EXPECTED_RUNNERS" ]; then
      fleet_active2="$(heal_umbra_runners)"
      if [ "${fleet_active2:-0}" -ge "$EXPECTED_RUNNERS" ]; then
        flipped "runner fleet: only ${fleet_active}/${EXPECTED_RUNNERS} runner services active on $UM (likely oom-kill) — SELF-HEALED via systemctl restart; now ${fleet_active2}/${EXPECTED_RUNNERS}."
      else
        flipped "runner fleet: ${fleet_active}/${EXPECTED_RUNNERS} runner services active on $UM; restart recovered only ${fleet_active2}/${EXPECTED_RUNNERS}. Investigate: umbra shell $UM -- systemctl status 'actions.runner.*'."
      fi
    else
      FLEET_UP=1
      note "runner fleet: ${fleet_active}/${EXPECTED_RUNNERS} runner services active on $UM — healthy"
    fi
  fi
else
  # No `umbra` on PATH => liveness cannot be checked at all. Say so loudly rather
  # than inheriting a healthy-looking default: a monitor that cannot see its
  # subject must report that, not go quiet.
  FLEET_UP=0
  flipped "runner fleet: the 'umbra' CLI is NOT on PATH for this job, so fleet liveness could not be checked at all. umbra lives in /usr/local/bin — add it to the LaunchAgent PATH (${OS_LAUNCHD_PREFIX}.ci-runner-guard)."
fi

# Focus bookkeeping: say so if the focus file is unreadable (healing is disabled),
# and let a deactivated repo with a job QUEUED for a self-hosted runner switch itself
# on (runner-focus.sh auto; it only ever turns runners ON, never off).
if [ "$FOCUS_BROKEN" -eq 1 ]; then
  flipped "runner focus: ${HOME}/.umbra/runner-focus.json exists but is unreadable — runner healing is DISABLED this cycle (healing without it would restart runners that were deactivated on purpose). Fix or delete the file."
elif [ "$FOCUS_ON" -eq 1 ] && [ "${FLEET_UP:-0}" -eq 1 ]; then
  _auto="$(_ut "$UMBRA_TIMEOUT_SLOW" "$HERE/runner-focus.sh" auto 2>/dev/null | grep 'turning it ON')"
  [ -z "$_auto" ] || flipped "runner focus: $(printf '%s' "$_auto" | tr '\n' ';')"
fi

# ── per-repo evaluation ───────────────────────────────────────────────────────

for r in "${REPOS[@]}"; do
  slug="$GH_USER/$r"
  cur=$(current_use_self_hosted "$slug")

  # ── OWNER PIN (2026-10-03) ────────────────────────────────────────────────
  # Repo variable CI_ROUTING_PIN = cloud | self-hosted makes routing an owner
  # decision the guard enforces instead of overriding. Unset = automatic.
  pin=$(gh variable get CI_ROUTING_PIN --repo "$slug" 2>/dev/null | tr -d '[:space:]')
  if [ "$pin" = "cloud" ] || [ "$pin" = "self-hosted" ]; then
    want=$([ "$pin" = "cloud" ] && echo false || echo true)
    if [ "$cur" != "$want" ]; then
      if gh variable set USE_SELF_HOSTED --repo "$slug" --body "$want" >/dev/null 2>&1; then
        flipped "$r: CI_ROUTING_PIN=$pin — restored USE_SELF_HOSTED=$want (was '$cur')"
      fi
    fi
    continue
  fi

  # ── DIRECTION A (original): cloud exhausted → self-hosted ─────────────────
  # Checked when USE_SELF_HOSTED is NOT 'true'. Direction A takes priority over
  # flip-back so a cloud-exhaustion scenario doesn't fight with saturation recovery.
  if [ "$cur" != "true" ]; then
    exhausted=0; reason=""
    if billing_exhausted; then exhausted=1; reason="billing API: included minutes exhausted"
    elif cloud_ci_infra_failing "$slug"; then exhausted=1; reason="heuristic: recent cloud CI runs failing at infra level (minutes-exhausted signature)"
    fi

    if [ "$exhausted" -eq 1 ]; then
      if runner_online "$slug"; then
        if gh variable set USE_SELF_HOSTED --repo "$slug" --body "true" >/dev/null 2>&1; then
          flipped "$r: FLIPPED to self-hosted ($reason). Re-run failed CI runs to pick it up."
        else
          flipped "$r: minutes exhausted but FAILED to set USE_SELF_HOSTED (check permissions)."
        fi
      else
        if try_runner_heal "$slug" && gh variable set USE_SELF_HOSTED --repo "$slug" --body "true" >/dev/null 2>&1; then
          flipped "$r: cloud minutes exhausted; Umbra runner '${RUNNER_UMBRA_MACHINE:-$OS_VM}' was down — SELF-HEALED (VM/service restart) and FLIPPED to self-hosted ($reason)."
        else
          flipped "$r: cloud minutes exhausted AND no self-hosted runner ONLINE — CI is DOWN. Check the Umbra runner: umbra start ${RUNNER_UMBRA_MACHINE:-$OS_VM} / umbra shell ${RUNNER_UMBRA_MACHINE:-$OS_VM} -- systemctl status 'actions.runner.*'."
        fi
      fi
      continue
    fi

    # Cloud is healthy + USE_SELF_HOSTED=false. This is normal when no exhaustion or
    # when USE_SELF_HOSTED was set to false by saturation detection (Direction B).
    # Flip BACK to self-hosted when runners are free and queue is clear.
    if runner_online "$slug" && ! ci_queue_backed_up "$slug"; then
      if gh variable set USE_SELF_HOSTED --repo "$slug" --body "true" >/dev/null 2>&1; then
        flipped "$r: RECOVERED — runners free + queue clear. FLIPPED back to self-hosted (USE_SELF_HOSTED=true)."
      else
        note "$r: cloud healthy, runners free, queue clear but FAILED to set USE_SELF_HOSTED=true (check permissions)"
      fi
    else
      note "$r: cloud CI healthy (USE_SELF_HOSTED=false; runners busy or queue not clear — not flipping back yet)"
    fi
    continue
  fi

  # ── DIRECTION B (NEW): self-hosted saturated → cloud ─────────────────────
  # Only runs when USE_SELF_HOSTED=true. Detects all runners busy + queue stalled.
  if all_runners_busy "$slug" && ci_queue_backed_up "$slug"; then
    # ALERT-FIRST by default. Flipping USE_SELF_HOSTED=false routes CI to cloud
    # (ubuntu-latest), but the Force workflows are self-hosted-tuned: verified
    # 2026-06-13 that flipping whatsapp to cloud FAILED gitleaks + Semgrep + Production
    # CI gates on branches that passed on self-hosted (allowlist/tool/service
    # config differs on cloud). A blind auto-flip would block all merges on false
    # security failures. So only auto-flip when CLOUD_CI_VERIFIED=true (a human has
    # confirmed cloud CI is green for that repo); otherwise alert + let a human act.
    if [ "${CLOUD_CI_VERIFIED:-false}" = "true" ] && gh variable set USE_SELF_HOSTED --repo "$slug" --body "false" >/dev/null 2>&1; then
      flipped "$r: SATURATION — flipped to cloud (CLOUD_CI_VERIFIED=true). Guard flips back when runners free + queue clears."
    else
      flipped "$r: SATURATION — all self-hosted runners busy + CI queue backed up >$SATURATION_QUEUE_MIN min. NOT auto-flipping to cloud (cloud config currently breaks gitleaks/Semgrep — see 2026-06-13). Free a runner, or after verifying cloud CI is green for this repo set CLOUD_CI_VERIFIED=true to enable the auto-flip."
    fi
    continue
  fi

  # Self-hosted is healthy (USE_SELF_HOSTED=true, no saturation).
  if runner_online "$slug"; then
    note "$r: self-hosted healthy (USE_SELF_HOSTED=true, runner online, no saturation)"
  elif umbra_fleet_running && ! ci_queue_backed_up "$slug"; then
    # Repo API shows zero runners, but the Umbra fleet is up (its runners are
    # ORG-registered — invisible to the repo-scoped API) and the CI queue is
    # moving. Healthy; do NOT heal (an umbra start here would double-fleet the box).
    note "$r: Umbra fleet up + queue clear (org-registered runners invisible to repo API) — healthy"
  elif [ "${FLEET_UP:-0}" = "1" ]; then
    # Fleet services are UP but this repo's API lists no runner. That is NOT an
    # API blind spot: these runners are REPO-scoped and normally visible here
    # (verified 2026-08-03). Services running while GitHub shows none means the
    # registration was dropped — GitHub prunes runners that stop connecting, and
    # a wrong guest clock is the usual cause. The unit keeps running against dead
    # credentials, so healing the VM cannot fix it; it needs re-registration.
    # This branch used to call the same state "load/saturation, not an outage",
    # which is exactly how the 2026-08-03 outage stayed silent.
    flipped "$r: runner services are UP but GitHub lists NO runner for this repo — the registration was dropped (GitHub prunes runners that stop connecting; check the guest clock first: umbra shell $UM -- chronyc tracking). Re-register: umbra runner add $UM --repo $r."
  elif [ "$PROVISIONING" -eq 1 ] || hands_off "$UM" "runner heal for $r"; then
    # Down because umbra rebuild is provisioning the guest: expected, not paged.
    note "$r: no self-hosted runner online while $UM is being provisioned ($PROV_REASON) — CI on self-hosted waits for the rebuild"
  else
    # Fleet is genuinely DOWN (the global check couldn't keep it up). Heal + alert.
    if try_runner_heal "$slug"; then
      flipped "$r: runners were OFFLINE (Umbra '${RUNNER_UMBRA_MACHINE:-$OS_VM}' VM or runner service down) — SELF-HEALED; runners back online, queued CI draining."
    else
      flipped "$r: USE_SELF_HOSTED=true but NO self-hosted runner is ONLINE — CI is queuing forever. Auto-heal didn't recover it: the usual cause is a VM-resume clock drift that made GitHub delete the registrations, which a restart CANNOT fix. Run 'ops/runner-reregister.sh' (re-registers every dead runner), or 'umbra start ${RUNNER_UMBRA_MACHINE:-$OS_VM}' if the guest itself is down. Last resort: set USE_SELF_HOSTED=false."
    fi
  fi
done

# ── guest clock drift ─────────────────────────────────────────────────────────
# GUEST CLOCK DRIFT — check this FIRST; it invalidates every other signal.
# 2026-08-24: $OS_VM woke 26 HOURS behind the host after the Mac suspended.
# GitHub refuses any runner operation once the clock is off by more than five
# minutes, so every runner failed to create a session, crash-looped, and six
# registrations were reaped. The outage read as a disk problem, then as a
# network problem. It was the clock.
#
# chrony was active throughout: its default `makestep 1 3` steps only during the
# first few updates, so after a suspend it slews forever and never catches up.
# A running NTP daemon is NOT evidence of a correct clock — measure the offset.
CLOCK_DRIFT_WARN_SEC=${CLOCK_DRIFT_WARN_SEC:-120}
CLOCK_DRIFT_CRIT_SEC=${CLOCK_DRIFT_CRIT_SEC:-300}

if command -v umbra >/dev/null 2>&1; then
  while read -r _m; do
    [ -n "$_m" ] || continue
    _host_epoch=$(date -u +%s)
    _guest_epoch=$(printf 'date -u +%%s\n' | _ut "$UMBRA_TIMEOUT" umbra shell "$_m" -- bash 2>/dev/null | tr -dc '0-9')
    _drift=""
    [ -n "$_guest_epoch" ] && _drift=$(( _host_epoch - _guest_epoch ))
    case "$(clock_drift_level "$_drift" "$CLOCK_DRIFT_WARN_SEC" "$CLOCK_DRIFT_CRIT_SEC")" in
      unknown)
        notes+=("$_m: guest clock unreadable — could not run date (guest down or ssh broken?)")
        ;;
      crit)
        if hands_off "$_m" "clock hard-set"; then
          notes+=("$_m: guest clock ${_drift}s off, but it is being provisioned — not hard-setting it")
          continue
        fi
        _before="$_drift"
        # `chronyc makestep` is NOT enough at a large offset: chrony marks every
        # source unusable ("^?") at that distance, so there is nothing selected
        # to step to, and it keeps reporting "0.000 seconds slow" against a stale
        # reference. Measured on 2026-08-24 at 10570s off — makestep returned
        # "200 OK" and changed nothing. Hard-set from the host, then let chrony
        # take over; its sources lock on immediately once the offset is small.
        _hostnow=$(date -u '+%Y-%m-%d %H:%M:%S')
        printf 'sudo systemctl stop chrony 2>/dev/null; sudo date -u -s "%s" >/dev/null 2>&1; sudo hwclock --systohc 2>/dev/null; sudo systemctl start chrony 2>/dev/null\n' "$_hostnow" \
          | _ut "$UMBRA_TIMEOUT" umbra shell "$_m" -- bash >/dev/null 2>&1 || true
        _guest_epoch=$(printf 'date -u +%%s\n' | _ut "$UMBRA_TIMEOUT" umbra shell "$_m" -- bash 2>/dev/null | tr -dc '0-9')
        _after=""
        [ -n "$_guest_epoch" ] && _after=$(( $(date -u +%s) - _guest_epoch ))
        findings+=("$_m: guest clock ${_before}s off (>=${CLOCK_DRIFT_CRIT_SEC}s) — GitHub refuses runners past 5min; hard-set from host, now ${_after:-unknown}s")
        if [ "$(clock_drift_level "${_after:-}" "$CLOCK_DRIFT_WARN_SEC" "$CLOCK_DRIFT_CRIT_SEC")" = "crit" ]; then
          findings+=("$_m: clock STILL ${_after}s off after a hard set — the guest may be re-freezing; check host sleep/VM suspend")
        fi
        ;;
      warn)
        notes+=("$_m: guest clock ${_drift}s off host (warn >=${CLOCK_DRIFT_WARN_SEC}s)")
        ;;
    esac
  done < <(_ut "$UMBRA_TIMEOUT" umbra list 2>/dev/null | awk 'NR>1 && $2=="running"{print $1}')
fi

# ── guest disk pressure ───────────────────────────────────────────────────────
# GUEST DISK PRESSURE. 2026-08-23: $OS_VM reached 0 bytes free of 58G — 18
# runners, ~40G of _work checkouts and node_modules. Every runner lost its
# GitHub session, all 18 registrations went offline, and four repos sat with
# runs that could never start. Nothing watched the disk, so the outage was
# invisible until CI had been dead for days.
#
# A full disk is not a "warn later" condition on a CI host: it takes the entire
# fleet down and the runners do not recover on their own once GitHub reaps the
# session. So this warns early and self-heals at critical.
DISK_WARN_PCT=${DISK_WARN_PCT:-80}
DISK_CRIT_PCT=${DISK_CRIT_PCT:-90}

if command -v umbra >/dev/null 2>&1; then
  while read -r _m; do
    [ -n "$_m" ] || continue
    _used=$(printf 'df --output=pcent / | tail -1 | tr -dc "0-9"\n' \
      | _ut "$UMBRA_TIMEOUT" umbra shell "$_m" -- bash 2>/dev/null | tr -dc '0-9')
    # An unreadable disk is UNKNOWN, never 0. Reporting "0% used" for a guest we
    # could not reach is how a dead host looks healthy.
    case "$(disk_pressure_level "$_used" "$DISK_WARN_PCT" "$DISK_CRIT_PCT")" in
    unknown)
      notes+=("$_m: guest disk unreadable — could not run df (guest down or ssh broken?)")
      continue
      ;;
    crit)
      if hands_off "$_m" "umbra prune"; then
        notes+=("$_m: guest disk ${_used}% used, but it is being provisioned — not pruning")
        continue
      fi
      _before="$_used"
      # idle-only and no fstrim (lib/safe-prune.sh); only a nearly-full guest disk or a host <25 GB free prunes a busy guest
      if command -v safe_umbra_prune >/dev/null 2>&1; then
        UMBRA_PRUNE_TIMEOUT="$UMBRA_TIMEOUT_SLOW" safe_umbra_prune "$_m" routine "$_used" >/dev/null 2>&1; _prc=$?
        [ "$_prc" = 3 ] && { notes+=("$_m: guest disk ${_used}% used, prune deferred: a CI job is running"); continue; }
      else
        notes+=("$_m: lib/safe-prune.sh missing, NOT pruning (refusing an unguarded prune)"); continue
      fi
      _after=$(printf 'df --output=pcent / | tail -1 | tr -dc "0-9"\n' \
        | _ut "$UMBRA_TIMEOUT" umbra shell "$_m" -- bash 2>/dev/null | tr -dc '0-9')
      findings+=("$_m: guest disk ${_before}% used (>=${DISK_CRIT_PCT}%) — ran umbra prune, now ${_after:-unknown}%")
      # Still critical after a prune means the disk needs a human: more runners
      # than the disk can hold, or something outside _work is growing.
      if [ "$(disk_pressure_level "${_after:-}" "$DISK_WARN_PCT" "$DISK_CRIT_PCT")" = "crit" ]; then
        findings+=("$_m: STILL ${_after}% after prune — grow the disk or remove runner instances")
      fi
      ;;
    warn)
      notes+=("$_m: guest disk ${_used}% used (warn >=${DISK_WARN_PCT}%) — prune will clear _work at >=80%")
      ;;
    esac
  done < <(_ut "$UMBRA_TIMEOUT" umbra list 2>/dev/null | awk 'NR>1 && $2=="running"{print $1}')
fi

# ── orphaned CI-throttle hook processes ───────────────────────────────────────
# 2026-09-22: when the guest silently lost /usr/bin/seq, the throttle hook's
# claim loop (internal/runner/throttle.go in umbra) spun forever waiting on a
# slot it could never even attempt to claim. GitHub cancelling the job it was
# throttling does NOT signal the hook — nothing sends it one — so it kept
# looping with its parent Runner.Worker already gone, reparented to pid 1. 10
# such orphans were found live on one guest.
#
# umbra's own hardening (umbra#55, same day) makes the hook check
# its parent's liveness every loop iteration and exit the moment it is gone,
# closing this specific shape. This probe alerts independently of whether that
# fix is installed on THIS guest yet, and of whether a future change
# reintroduces an unbounded hook loop — a monitor for the CLASS, not just the
# one incident.
#
# ALERT-ONLY, deliberately: killing an orphan here would be a second
# destructive lever on a guard that already has exactly one
# (rebuild_corrupt_guest), and an orphan not holding a slot is wasted CPU, not
# an outage. What DOES matter is the precursor it signals: an orphan that
# claimed a slot before dying strands it until job-started.sh's reap() clears
# it at MAX_AGE_MIN (3h default) — which is the same slow-motion pool drain
# ThrottleScript's own doc describes for a missed JOB_COMPLETED.
if command -v umbra >/dev/null 2>&1; then
  while read -r _m; do
    [ -n "$_m" ] || continue
    _orphans=$(printf 'ps -Ao ppid,pid,args 2>/dev/null | grep -E "job-started\\.sh|job-completed\\.sh" | while read -r _ppid _pid _rest; do
  [ "$_ppid" = "1" ] && echo "$_pid"
done\n' | _ut "$UMBRA_TIMEOUT" umbra shell "$_m" -- bash 2>/dev/null | tr -d '\r')
    _ocount=0
    [ -n "$_orphans" ] && _ocount=$(printf '%s\n' "$_orphans" | grep -c .)
    if [ "${_ocount:-0}" -gt 0 ]; then
      findings+=("$_m: ${_ocount} orphaned CI-throttle hook process(es) found (parent pid 1): pids [$(printf '%s' "$_orphans" | tr '\n' ' ')]. GitHub already cancelled the job(s) these were throttling; each costs CPU, not correctness, but is the exact precursor to a stranded slot outliving MAX_AGE_MIN. Confirm umbra's throttle hardening is installed on this guest (umbra#55): umbra shell $_m -- grep -c PARENT_PID /opt/umbra-ci/job-started.sh (expect >=1; 0 or a missing file means the pre-hardening hook is still installed and this WILL recur).")
    fi
  done < <(_ut "$UMBRA_TIMEOUT" umbra list 2>/dev/null | awk 'NR>1 && $2=="running"{print $1}')
fi

# ── shared semgrep venv freshness ─────────────────────────────────────────────
# SHARED SEMGREP VENV. The SAST gate uses /opt/semgrep-venv on the fleet instead
# of pip-installing semgrep per run (a 72MB wheel that blew the job's timeout
# under contention on 2026-08-23). The gate deliberately NEVER upgrades that
# venv itself: an in-place `pip install --upgrade` can corrupt a scan another
# runner is executing against the same venv.
#
# That leaves the refresh to something scheduled — this guard. Without it the
# gate emits a staleness notice nobody acts on, and SAST silently runs weaker
# than intended. Skipped while any semgrep is executing, for the same
# concurrent-corruption reason the gate avoids.
SEMGREP_VENV_MAX_AGE_DAYS=${SEMGREP_VENV_MAX_AGE_DAYS:-30}

if command -v umbra >/dev/null 2>&1; then
  while read -r _m; do
    [ -n "$_m" ] || continue
    _sg=$(printf 'V=/opt/semgrep-venv
if [ ! -x "$V/bin/semgrep" ]; then echo ABSENT; exit 0; fi
if [ -n "$(find "$V" -maxdepth 0 -mtime -%s 2>/dev/null)" ]; then echo FRESH; exit 0; fi
if pgrep -f "semgrep" >/dev/null 2>&1; then echo BUSY; exit 0; fi
if sudo "$V/bin/pip" install --quiet --upgrade semgrep >/dev/null 2>&1; then
  sudo touch "$V"; echo "REFRESHED $("$V/bin/semgrep" --version 2>/dev/null)"
else
  echo REFRESH_FAILED
fi\n' "$SEMGREP_VENV_MAX_AGE_DAYS" | _ut "$UMBRA_TIMEOUT_SLOW" umbra shell "$_m" -- bash 2>/dev/null | tr -d '\r' | tail -1)
    case "$_sg" in
      REFRESHED*) findings+=("$_m: shared semgrep venv was >${SEMGREP_VENV_MAX_AGE_DAYS}d old — refreshed (${_sg#REFRESHED })") ;;
      REFRESH_FAILED) findings+=("$_m: shared semgrep venv is stale and the refresh FAILED — SAST is running an old analyzer") ;;
      BUSY) notes+=("$_m: shared semgrep venv is stale but a scan is running — will retry next cycle") ;;
      ABSENT) notes+=("$_m: no shared semgrep venv — SAST jobs fall back to a per-run pip install (slow)") ;;
    esac
  done < <(_ut "$UMBRA_TIMEOUT" umbra list 2>/dev/null | awk 'NR>1 && $2=="running"{print $1}')
fi

# ── report ────────────────────────────────────────────────────────────────────

if [ ${#findings[@]} -eq 0 ]; then
  echo "[ci-runner-guard] OK — no action needed."
  [ ${#notes[@]} -gt 0 ] && printf '  %s\n' ${notes[@]+"${notes[@]}"}
  if [ "$PROVISIONING" -eq 1 ]; then
    write_status "runner" "true" "$UM: $PROV_REASON — guard hands-off this machine" \
      "$(PR="$PROV_REASON" UMV="$UM" python3 -c 'import json,os; print(json.dumps({"provisioning":True,"machine":os.environ["UMV"],"reason":os.environ["PR"]}))')"
  else
    write_status "runner" "true" "no action needed — all runners healthy" '{}'
  fi
  exit 0
fi
msg="CI Runner Guard — ${#findings[@]} action(s):"$'\n'"$(printf '  • %s\n' ${findings[@]+"${findings[@]}"})"
[ ${#notes[@]} -gt 0 ] && msg="$msg"$'\n'"$(printf '  · %s\n' ${notes[@]+"${notes[@]}"})"
echo "$msg"
"$HERE/notify.sh" "CI Runner Guard" "$msg" >/dev/null 2>&1 || true
DETAIL=$(printf '%s\n' ${findings[@]+"${findings[@]}"} | python3 -c 'import json,sys; print(json.dumps({"items":[l for l in sys.stdin.read().splitlines() if l]}))')
write_status "runner" "warn" "${#findings[@]} runner action(s) taken" "$DETAIL"
exit 1
