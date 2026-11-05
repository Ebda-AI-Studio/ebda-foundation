#!/usr/bin/env bash
# umbra_provisioning — is `umbra rebuild` provisioning this machine right now?
#
# 2026-10-16 02:53: ci-runner-guard rebooted umbra-ci6 mid-rebuild ("SSH dead +
# no runner → reboot") — a guest being provisioned looks exactly like a hung
# one. umbra rebuild now writes ~/.umbra/provisioning/<vm> with expires=<epoch>
# (umbra cmd/umbra/provisioning.go). The guard stands down while it is fresh.
# The TTL is the whole point: a dead rebuild must not disable the guard forever.
set -euo pipefail
. "$(dirname "$0")/../umbra-provisioning.sh"
_pass=0; _fail=0
eq() { if [ "$2" = "$3" ]; then echo "PASS: $1"; _pass=$((_pass+1)); else echo "FAIL: $1 — got '$2' want '$3'"; _fail=$((_fail+1)); fi; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export UMBRA_ROOT="$T/umbra"
mkdir -p "$UMBRA_ROOT/provisioning"
M="$UMBRA_ROOT/provisioning/umbra-ci6"
NOW=1800000000
st() { umbra_provisioning umbra-ci6 "$NOW" >/dev/null 2>&1 && echo yes || echo no; }

eq "no marker → not provisioning" "$(st)" "no"

printf 'expires=%s\nphase=kernel\npid=4242\nupdated=x\n' $((NOW+1800)) > "$M"
eq "fresh marker → provisioning" "$(st)" "yes"
eq "reason names the phase and the minutes left" \
   "$(umbra_provisioning umbra-ci6 "$NOW")" "umbra rebuild in progress (phase kernel, guard resumes in 30 min)"
eq "another machine is not covered" \
   "$(umbra_provisioning other "$NOW" >/dev/null 2>&1 && echo yes || echo no)" "no"

printf 'expires=%s\nphase=kernel\n' "$NOW" > "$M"
eq "expires exactly now → expired (not provisioning)" "$(st)" "no"
printf 'expires=%s\nphase=kernel\n' $((NOW-60)) > "$M"
eq "expired marker (a dead rebuild) → not provisioning" "$(st)" "no"

# A bogus far-future expiry must not park the guard: cap at 4h.
printf 'expires=%s\nphase=kernel\n' $((NOW+5*3600)) > "$M"
eq "expiry beyond the 4h cap → ignored" "$(st)" "no"
printf 'expires=%s\nphase=kernel\n' $((NOW+4*3600)) > "$M"
eq "expiry exactly at the 4h cap → honoured" "$(st)" "yes"

# Unreadable / malformed = not provisioning. Fail OPEN to the guard's normal
# behaviour: a broken marker must never silence it.
printf 'phase=kernel\n' > "$M";             eq "no expires= → ignored" "$(st)" "no"
printf 'expires=soon\n' > "$M";             eq "non-numeric expires → ignored" "$(st)" "no"
: > "$M";                                   eq "empty marker → ignored" "$(st)" "no"

# A path-traversal machine name never reads outside the provisioning dir.
eq "machine name with a slash → not provisioning" \
   "$(umbra_provisioning ../x "$NOW" >/dev/null 2>&1 && echo yes || echo no)" "no"

# Default clock is the wall clock.
printf 'expires=%s\nphase=health\n' $(( $(date +%s) + 600 )) > "$M"
eq "no NOW argument → uses the wall clock" \
   "$(umbra_provisioning umbra-ci6 >/dev/null 2>&1 && echo yes || echo no)" "yes"

# ── host sleep (M4) ──────────────────────────────────────────────────────────
# umbra re-stamps the marker every 30s from the wall clock, but a guard that
# fires the moment the Mac wakes can read a stamp made before the sleep. A
# marker whose recorded pid is STILL a live umbra process is a rebuild in
# progress, whatever its expiry says. A dead pid keeps the TTL semantics.
# UMBRA_PROVISIONING_PROC_RE is the command-name match (default: umbra); the
# test points it at `sleep` to have a live, identifiable process.
sleep 30 & LIVE=$!
printf 'expires=%s\nphase=kernel\npid=%s\n' $((NOW-600)) "$LIVE" > "$M"
eq "expired, but the rebuild pid is alive (host slept) → still provisioning" \
   "$(UMBRA_PROVISIONING_PROC_RE='sleep' umbra_provisioning umbra-ci6 "$NOW" >/dev/null 2>&1 && echo yes || echo no)" "yes"
eq "…and the reason says why" \
   "$(UMBRA_PROVISIONING_PROC_RE='sleep' umbra_provisioning umbra-ci6 "$NOW" | grep -c 'still running')" "1"
eq "expired, pid alive but NOT an umbra process (pid reuse) → not provisioning" \
   "$(umbra_provisioning umbra-ci6 "$NOW" >/dev/null 2>&1 && echo yes || echo no)" "no"
printf 'expires=%s\nphase=kernel\npid=%s\n' $((NOW-5*3600)) "$LIVE" > "$M"
eq "expired more than 4h ago → not provisioning even with a live pid" \
   "$(UMBRA_PROVISIONING_PROC_RE='sleep' umbra_provisioning umbra-ci6 "$NOW" >/dev/null 2>&1 && echo yes || echo no)" "no"
kill "$LIVE" 2>/dev/null || true; wait "$LIVE" 2>/dev/null || true
printf 'expires=%s\nphase=kernel\npid=%s\n' $((NOW-600)) "$LIVE" > "$M"
eq "expired and the pid is gone (a dead rebuild) → not provisioning" \
   "$(UMBRA_PROVISIONING_PROC_RE='sleep' umbra_provisioning umbra-ci6 "$NOW" >/dev/null 2>&1 && echo yes || echo no)" "no"
printf 'expires=%s\nphase=kernel\npid=notanumber\n' $((NOW-600)) > "$M"
eq "garbage pid → not provisioning" "$(st)" "no"

echo "umbra-provisioning: $_pass passed, $_fail failed"
[ "$_fail" -eq 0 ]
