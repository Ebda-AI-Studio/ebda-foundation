#!/usr/bin/env bash
# Test disk_pressure_level: thresholds, boundaries, and unknown-vs-zero.
set -euo pipefail
. "$(dirname "$0")/../disk-pressure.sh"

_pass=0; _fail=0
assert_eq() {
  local label="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then echo "PASS: $label"; _pass=$((_pass+1))
  else echo "FAIL: $label — got '$got' want '$want'"; _fail=$((_fail+1)); fi
}

assert_eq "0% is ok"            "$(disk_pressure_level 0)"        "ok"
assert_eq "57% is ok"           "$(disk_pressure_level 57)"       "ok"
assert_eq "79% is ok"           "$(disk_pressure_level 79)"       "ok"
assert_eq "80% warns (boundary)" "$(disk_pressure_level 80)"      "warn"
assert_eq "89% warns"           "$(disk_pressure_level 89)"       "warn"
assert_eq "90% is crit (boundary)" "$(disk_pressure_level 90)"    "crit"
assert_eq "100% is crit"        "$(disk_pressure_level 100)"      "crit"

# The outage reading itself: the disk was 100% full.
assert_eq "the 2026-08-23 reading" "$(disk_pressure_level 100)"   "crit"

# UNKNOWN must never collapse to ok/0 — a guest we cannot reach is not healthy.
assert_eq "empty is unknown"    "$(disk_pressure_level '')"       "unknown"
assert_eq "no arg is unknown"   "$(disk_pressure_level)"          "unknown"
assert_eq "garbage is unknown"  "$(disk_pressure_level 'N/A')"    "unknown"
assert_eq "partial digits are unknown" "$(disk_pressure_level '9x')" "unknown"

# Custom thresholds are honoured.
assert_eq "custom warn"         "$(disk_pressure_level 60 50 70)" "warn"
assert_eq "custom crit"         "$(disk_pressure_level 75 50 70)" "crit"


# ── host readers (added 2026-09-04) ───────────────────────────────────────────
# A 98%-full HOST wedged umbra-ci6: the guest booted, never reached sshd, and
# console.log stayed 0 bytes. Nothing read the host disk — this guard measured
# only the GUEST, and mac-maintenance.sh's 20GB threshold ran WEEKLY, so the
# disk crossed from healthy to fleet-fatal inside one window.

# A path that does not exist must yield EMPTY, which disk_pressure_level then
# calls "unknown". If it ever returned 0 the host would read as pristine.
assert_eq "missing volume -> empty" "$(host_disk_used_pct /no/such/volume)" ""
assert_eq "missing volume -> unknown" \
  "$(disk_pressure_level "$(host_disk_used_pct /no/such/volume)")" "unknown"
assert_eq "missing volume free -> empty" "$(host_disk_free_gb /no/such/volume)" ""

# A real volume must give a plain integer 0-100 — no % sign, no whitespace, no
# device column bleeding in. The guard does integer comparison on this.
_used="$(host_disk_used_pct /)"
case "$_used" in
  ''|*[!0-9]*) assert_eq "root volume yields digits" "$_used" "<digits>" ;;
  *) [ "$_used" -ge 0 ] && [ "$_used" -le 100 ] \
       && assert_eq "root used% in range" "ok" "ok" \
       || assert_eq "root used% in range" "$_used" "0-100" ;;
esac

_free="$(host_disk_free_gb /)"
case "$_free" in
  ''|*[!0-9]*) assert_eq "root volume free yields digits" "$_free" "<digits>" ;;
  *) assert_eq "root free is numeric" "ok" "ok" ;;
esac

# APFS: on macOS the Data volume is the honest read. Where it exists, it must be
# readable — a silent empty here is what let the host go unmeasured.
if [ -d /System/Volumes/Data ]; then
  _d="$(host_disk_used_pct /System/Volumes/Data)"
  case "$_d" in
    ''|*[!0-9]*) assert_eq "Data volume readable" "$_d" "<digits>" ;;
    *) assert_eq "Data volume readable" "ok" "ok" ;;
  esac
fi

echo "disk-pressure: $_pass passed, $_fail failed"
[ "$_fail" -eq 0 ]
