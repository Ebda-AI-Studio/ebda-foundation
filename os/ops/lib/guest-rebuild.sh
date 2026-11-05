# shellcheck shell=bash
# ops/lib/guest-rebuild.sh — the rate limit + cooldown in front of the ONE
# destructive remedy the CI runner guard has.
#
# WHY THIS EXISTS (measured 2026-09-16). The CI guest fwb-ci6 corrupted TWICE in
# two days, both times ext4 going read-only:
#
#   EXT4-fs error (device vda1): mb_free_blocks: ... block bitmap corrupt
#   EXT4-fs (vda1): Detected aborted journal
#   EXT4-fs (vda1): Remounting filesystem read-only
#
# A reboot did NOT fix it (the stop was forced at 120s, readiness failed, and the
# VM process burned 0.01s of CPU over a 10s sample — it was not executing).
# `umbra rebuild fwb-ci6 --yes` DID: 8m35s, 20 runners restored, fresh disk
# CLEAN error_count=0. Ahmad authorised the guard to do that automatically:
# "rebuild it if it comes back".
#
# THE DANGER THIS GUARDS. `umbra rebuild` runs `umbra rm`, which deletes the
# machine directory — snapshots included. Everything in the guest is gone:
# packages, caches, ~40 GB of runner _work checkouts. The guard ticks every 30
# minutes, so a verdict that persists is 48 destructive rebuilds a day. That is
# the restart-loop pathology of 2026-08-27→09-07 reproduced one level up, with a
# much bigger hammer — which is exactly why the arithmetic lives here, apart
# from the probing, and is unit-tested with synthesised clocks.
#
# Source it the way the guard sources its other libs:
#   . "$(dirname "$0")/lib/guest-rebuild.sh" 2>/dev/null \
#     || . "$HOME/.claude/scripts/lib/guest-rebuild.sh" 2>/dev/null || true
#
# The CALLER must fail CLOSED when this lib is missing: no guardrail means no
# rebuild, never an unguarded one.

# Rolling history of automatic rebuilds, per machine. Runtime state, not
# deployed config — a marker under ~/.whisky-os-state survives the script sync
# (the same reasoning as the fleet park marker in lib/runner-fleet.sh).
GUEST_REBUILD_STATE="${GUEST_REBUILD_STATE:-$HOME/.whisky-os-state/guest-rebuild-history.json}"

# At most MAX rebuilds per rolling WINDOW, and never two inside MIN_GAP.
#
#   MAX=1 / WINDOW=12h (tightened 2026-11-02 after a rebuild loop on the image
#     kernel: a rebuild that does not restore service must page, not repeat) —
#   was MAX=2 / WINDOW=24h — the measured worst case is 2 corruptions in 2 days, so
#     two covers it with nothing spare. A THIRD inside 24h means rebuilding is
#     not fixing the cause (suspect the host or the guest kernel: 14 of 15
#     oopses on 2026-09-16 faulted at the same AppArmor address), and that needs
#     Ahmad rather than another 9-minute destructive retry.
#   MIN_GAP=3h — on 2026-09-15 a freshly rebuilt, clean-disk guest wedged again
#     ~37 minutes later. A gap shorter than that lets the guard rebuild-loop
#     against a cause that is not the disk. 3h gives a rebuilt guest time to
#     prove itself under real CI load before it may be destroyed again.
GUEST_REBUILD_MAX="${GUEST_REBUILD_MAX:-1}"
GUEST_REBUILD_WINDOW_SEC="${GUEST_REBUILD_WINDOW_SEC:-43200}"
GUEST_REBUILD_MIN_GAP_SEC="${GUEST_REBUILD_MIN_GAP_SEC:-10800}"

# guest_rebuild_decide <now> <max> <window> <min_gap> [epoch...]
#   -> allow | cooldown:<seconds remaining> | limit:<count in window>
#
# PURE: no clock, no state file, no side effects — so the guardrail itself is
# testable with synthesised timestamps.
#
# The LIMIT is reported before the cooldown when both apply. They are not
# equally urgent: a cooldown clears on its own, while hitting the limit means a
# human has to look. Reporting the transient one would bury the actionable one.
guest_rebuild_decide() {
  local now="${1:?}" max="${2:?}" window="${3:?}" gap="${4:?}"
  shift 4
  local e recent=0 newest=0
  for e in "$@"; do
    # A non-numeric entry is corruption in the state file. Ignore it: it is
    # neither permission to rebuild nor evidence that one happened.
    case "$e" in ''|*[!0-9]*) continue ;; esac
    if [ $((now - e)) -lt "$window" ]; then recent=$((recent + 1)); fi
    if [ "$e" -gt "$newest" ]; then newest="$e"; fi
  done

  if [ "$recent" -ge "$max" ]; then
    printf 'limit:%s\n' "$recent"
    return 0
  fi
  if [ "$newest" -gt 0 ] && [ $((now - newest)) -lt "$gap" ]; then
    printf 'cooldown:%s\n' "$((gap - (now - newest)))"
    return 0
  fi
  printf 'allow\n'
}

# guest_rebuild_history <machine> -> ascending, space-separated epochs (or empty)
#
# A corrupt or unreadable state file reads as EMPTY, never as a crash. It must
# also never read as a phantom rebuild — see guest_rebuild_decide.
guest_rebuild_history() {
  local m="${1:?}"
  [ -f "$GUEST_REBUILD_STATE" ] || return 0
  GRH_M="$m" python3 -c '
import json, os, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
    xs = d.get(os.environ["GRH_M"], []) if isinstance(d, dict) else []
    print(" ".join(str(int(x)) for x in sorted(xs)))
except Exception:
    pass' "$GUEST_REBUILD_STATE" 2>/dev/null
}

# guest_rebuild_record <machine> [epoch]
#
# Same-directory temp + os.replace: rename(2) is atomic within a filesystem, so
# a crash mid-write cannot leave a truncated history that reads as "no rebuilds
# yet" and re-opens the budget (lib/atomic.sh documents the class).
#
# Entries are pruned relative to the epoch being RECORDED, not to wall clock, so
# the file stays bounded and the history is a rolling window around its newest
# entry.
guest_rebuild_record() {
  local m="${1:?}" now="${2:-}"
  [ -n "$now" ] || now="$(date -u +%s)"
  local dir
  dir="$(dirname "$GUEST_REBUILD_STATE")"
  mkdir -p "$dir" 2>/dev/null || return 1
  GRR_M="$m" GRR_NOW="$now" GRR_WIN="$GUEST_REBUILD_WINDOW_SEC" python3 -c '
import json, os, sys
path = sys.argv[1]
m   = os.environ["GRR_M"]
now = int(os.environ["GRR_NOW"])
win = int(os.environ["GRR_WIN"])
try:
    d = json.load(open(path, encoding="utf-8"))
    if not isinstance(d, dict):
        d = {}
except Exception:
    d = {}
xs = []
for x in d.get(m, []):
    try:
        xs.append(int(x))
    except Exception:
        pass
xs.append(now)
d[m] = sorted(x for x in xs if now - x < win)
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(d, fh, indent=2)
os.replace(tmp, path)' "$GUEST_REBUILD_STATE" 2>/dev/null
}

# guest_rebuild_allowed <machine> [now] -> allow | cooldown:<s> | limit:<n>
guest_rebuild_allowed() {
  local m="${1:?}" now="${2:-}"
  [ -n "$now" ] || now="$(date -u +%s)"
  local hist
  hist="$(guest_rebuild_history "$m")"
  # shellcheck disable=SC2086  # $hist is a whitespace-separated epoch list, split on purpose
  guest_rebuild_decide "$now" "$GUEST_REBUILD_MAX" "$GUEST_REBUILD_WINDOW_SEC" \
    "$GUEST_REBUILD_MIN_GAP_SEC" $hist
}
