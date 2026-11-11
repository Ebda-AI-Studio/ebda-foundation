#!/usr/bin/env bash
# Test clock_drift_level: thresholds, sign-independence, unknown-vs-zero.
set -euo pipefail
. "$(dirname "$0")/../clock-drift.sh"
_pass=0; _fail=0
eq() { if [ "$2" = "$3" ]; then echo "PASS: $1"; _pass=$((_pass+1)); else echo "FAIL: $1 — got '$2' want '$3'"; _fail=$((_fail+1)); fi; }

eq "0s is ok"              "$(clock_drift_level 0)"        "ok"
eq "119s is ok"            "$(clock_drift_level 119)"      "ok"
eq "120s warns (boundary)" "$(clock_drift_level 120)"      "warn"
eq "299s warns"            "$(clock_drift_level 299)"      "warn"
eq "300s is crit"          "$(clock_drift_level 300)"      "crit"

# GitHub refuses runner operations past five minutes, so crit must fire below it.
eq "the GitHub 5-min limit is crit" "$(clock_drift_level 301)" "crit"
# The actual outage reading: 26 hours behind.
eq "94512s (the 2026-08-24 drift)"  "$(clock_drift_level 94512)" "crit"

# Ahead is as broken as behind.
eq "negative drift is absolute"  "$(clock_drift_level -94512)" "crit"
eq "small negative is ok"        "$(clock_drift_level -5)"     "ok"

# UNKNOWN must never collapse to ok/0.
eq "empty is unknown"    "$(clock_drift_level '')"     "unknown"
eq "no arg is unknown"   "$(clock_drift_level)"        "unknown"
eq "garbage is unknown"  "$(clock_drift_level 'N/A')"  "unknown"
eq "partial is unknown"  "$(clock_drift_level '9x')"   "unknown"

eq "custom thresholds"   "$(clock_drift_level 60 30 90)" "warn"

echo "clock-drift: $_pass passed, $_fail failed"
[ "$_fail" -eq 0 ]
