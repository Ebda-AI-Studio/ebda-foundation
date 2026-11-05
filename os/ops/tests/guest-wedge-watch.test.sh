#!/usr/bin/env bash
# guest-wedge-watch: alert on 2 slow guest execs in a row or a job past its ceiling; restart ONLY when the guest
# is slow AND no job progressed for 30+ min. Fixture-driven: umbra, notify and the GitHub job list are stubs.
set -uo pipefail
export OS_UMBRA_VMS=umbra-ci6   # fixture guest name; the shipped default lives only in os.env
cd "$(dirname "$0")/.."; OPS="$(pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
_pass=0; _fail=0
pass() { echo "PASS: $1"; _pass=$((_pass+1)); }
fail() { echo "FAIL: $1"; _fail=$((_fail+1)); }

NOW=2000000000
cat > "$TMP/umbra" <<EOF2
#!/usr/bin/env bash
echo "\$*" >> "$TMP/umbra.calls"
[ "\$1" = doctor ] && echo '{"rung":"guest-io-stall"}'
exit 0
EOF2
cat > "$TMP/notify" <<EOF2
#!/usr/bin/env bash
echo "\$1" >> "$TMP/notify.calls"
EOF2
chmod +x "$TMP/umbra" "$TMP/notify"

# run <tag> <probe-seconds> <jobs-lines...>  — the state dir persists per tag so consecutive runs accumulate
run() {
  local tag="$1" probe="$2"; shift 2
  local r="$TMP/run-$tag"; mkdir -p "$r"; cp "${SCRIPT:-$OPS/guest-wedge-watch.sh}" "$r/guest-wedge-watch.sh"
  ln -sfn "${LIBDIR:-$OPS/lib}" "$r/lib"; : > "$r/jobs"; for l in "$@"; do echo "$l" >> "$r/jobs"; done
  : > "$TMP/umbra.calls"; : > "$TMP/notify.calls"
  env HOME="$TMP/home" WEDGE_STATE="$TMP/state-$tag" WEDGE_NOW="$NOW" UMBRA_BIN="${UMBRA_OVERRIDE:-$TMP/umbra}" WEDGE_NOTIFY="$TMP/notify" \
    WEDGE_HOST_FREE_CMD="${T_FREE:-echo 500}" WEDGE_SWAP_CMD="${T_SWAP:-echo 0 4096}" WEDGE_GUEST_PRESSURE_CMD="${T_GUEST:-echo 0 0}" WEDGE_PROBE_CMD="echo $probe" WEDGE_JOBS_CMD="cat $r/jobs" UMBRA_ROOT="$TMP/umbra-root" ${EXTRA_ENV:-} \
    bash "$r/guest-wedge-watch.sh" > "$TMP/log-$tag" 2>&1
  PAGES=$(grep -c . "$TMP/notify.calls"); DOCTOR=$(grep -c '^doctor' "$TMP/umbra.calls"); STOPS=$(grep -c '^stop' "$TMP/umbra.calls"); STARTS=$(grep '^start' "$TMP/umbra.calls" | grep -vc -- '--help')
}
mkdir -p "$TMP/home"
FRESH="gh#1|$((NOW-600))|$((NOW-60))"                      # started 10 min ago, a step finished 1 min ago
STALE="gh#2|$((NOW-4000))|$((NOW-3000))"                    # last step 50 min ago, started 66 min ago (also an OVERRUN)
STALE_OK="gh#3|$((NOW-2400))|$((NOW-2400))"                 # started 40 min ago, no step since: no-progress but under the 45 min ceiling

run a 5 "$FRESH"
[ "$PAGES$DOCTOR$STOPS" = "000" ] && pass "A healthy guest: no page, no doctor, no restart" || fail "A (pages=$PAGES doctor=$DOCTOR stops=$STOPS)"

run b 400 "$FRESH"
[ "$PAGES$STOPS" = "00" ] && pass "B ONE slow exec is not an incident" || fail "B (pages=$PAGES)"

run c 400 "$FRESH"; run c 400 "$FRESH"
[ "$PAGES" = 1 ] && [ "$DOCTOR" = 1 ] && [ "$STOPS" = 0 ] && pass "C two slow execs in a row with jobs progressing: alert + umbra doctor, NO restart" || { fail "C (pages=$PAGES doctor=$DOCTOR stops=$STOPS)"; cat "$TMP/log-c"; }
run c 400 "$FRESH"
[ "$PAGES" = 0 ] && pass "C2 the next run does not re-page inside the repeat window" || fail "C2 re-paged ($PAGES)"

run e 9999 "$STALE_OK"; run e 9999 "$STALE_OK"
[ "$STOPS" = 1 ] && [ "$STARTS" = 1 ] && pass "E slow x2 AND no job progress for 40 min: umbra stop + start" || { fail "E restart (stops=$STOPS starts=$STARTS)"; cat "$TMP/log-e"; }

# umbra U1: automated starts carry --fsck-if-dirty when the installed umbra supports it, and stay plain when it does not
cat > "$TMP/umbra-new" <<EOF3
#!/usr/bin/env bash
echo "\$*" >> "$TMP/umbra.calls"
[ "\$1" = start ] && [ "\$2" = --help ] && echo "      --fsck-if-dirty   snapshot, fsck, start"
[ "\$1" = doctor ] && echo '{"rung":"guest-io-stall"}'
exit 0
EOF3
chmod +x "$TMP/umbra-new"
grep -qx 'start umbra-ci6' "$TMP/umbra.calls" && pass "E2 an umbra without the flag is started plainly" || fail "E2 plain start missing ($(cat "$TMP/umbra.calls" | tr '\n' ';'))"
rm -rf "$TMP/state-e2"
UMBRA_OVERRIDE="$TMP/umbra-new" run e2 9999 "$STALE_OK"; UMBRA_OVERRIDE="$TMP/umbra-new" run e2 9999 "$STALE_OK"
grep -qx 'start --fsck-if-dirty umbra-ci6' "$TMP/umbra.calls" && pass "E3 an umbra WITH the flag is started with --fsck-if-dirty" || fail "E3 flag missing ($(cat "$TMP/umbra.calls" | tr '\n' ';'))"
run e 9999 "$STALE_OK"
[ "$STOPS" = 0 ] && pass "E2 cooldown: a second restart inside 2 h does not happen" || fail "E2 restarted again"

run f 5 "$STALE"
[ "$STOPS" = 0 ] && [ "$PAGES" = 1 ] && [ "$DOCTOR" = 1 ] && pass "F a job past its ceiling on a RESPONSIVE guest: alert + doctor, never a restart" || { fail "F overrun (pages=$PAGES doctor=$DOCTOR stops=$STOPS)"; cat "$TMP/log-f"; }
run f 5 "$STALE"
[ "$PAGES" = 0 ] && pass "F2 the same overrun is alerted once" || fail "F2 re-alerted"

run g 400 "$FRESH"; run g 5 "$FRESH"; run g 400 "$FRESH"
[ "$PAGES" = 0 ] && pass "G a fast probe resets the slow streak (slow, fast, slow is not two in a row)" || fail "G streak not reset"

run h 9999; run h 9999
[ "$PAGES" = 1 ] && [ "$STOPS" = 0 ] && pass "H idle guest (no jobs) that is slow x2: alert, but nothing to restart for" || fail "H (pages=$PAGES stops=$STOPS)"

mkdir -p "$TMP/umbra-root/provisioning"; echo "expires=$((NOW+1800))" > "$TMP/umbra-root/provisioning/umbra-ci6"
run i 9999 "$STALE_OK"; run i 9999 "$STALE_OK"
[ "$PAGES$STOPS" = "00" ] && grep -q "provisioning" "$TMP/log-i" && pass "I a guest that umbra rebuild is provisioning is left alone" || { fail "I provisioning (pages=$PAGES stops=$STOPS)"; cat "$TMP/log-i"; }
rm -rf "$TMP/umbra-root"

# ---- host pressure alerts (free disk, swap) ----
T_FREE='echo 12' T_SWAP='echo 3000 4096' run j 5 "$FRESH"
[ "$PAGES" = 1 ] && grep -q "free disk" "$TMP/notify.calls" && pass "J free disk 12 GB < 30 (swap 73% is quiet): exactly one page" || { fail "J disk (pages=$PAGES)"; cat "$TMP/log-j"; }
T_FREE='echo 12' T_SWAP='echo 3000 4096' run j 5 "$FRESH"
[ "$PAGES" = 0 ] && pass "J2 the same condition does not re-page inside the repeat window" || fail "J2 re-paged"
T_FREE='echo 80' T_SWAP='echo 3900 4096' run k 5 "$FRESH"
[ "$PAGES" = 1 ] && grep -q "swap" "$TMP/notify.calls" && pass "K swap 95% used: exactly one page" || { fail "K swap (pages=$PAGES)"; cat "$TMP/log-k"; }
T_FREE='echo 80' T_SWAP='echo 500 4096' run l 5 "$FRESH"
[ "$PAGES" = 0 ] && pass "L healthy host (80 GB free, swap 12%): silent" || fail "L paged ($PAGES)"

# ---- guest I/O + swap pressure (the 17:08Z swap storm) ----
T_GUEST='echo 43 99 40' run n 5 "$FRESH"
[ "$PAGES" = 2 ] && grep -q "I/O stall" "$TMP/notify.calls" && grep -q "swap 99" "$TMP/notify.calls" && pass "N guest io-full 43 and swap 99: one page each" || { fail "N guest pressure (pages=$PAGES)"; cat "$TMP/log-n"; }
T_GUEST='echo 43 99 40' run n 5 "$FRESH"
[ "$PAGES" = 0 ] && pass "N2 the same condition does not re-page inside the hour" || fail "N2 re-paged"
T_GUEST='echo 8 40 60' run o 5 "$FRESH"
[ "$PAGES" = 0 ] && pass "O normal guest (io 8, swap 40): silent" || fail "O paged ($PAGES)"
T_GUEST='echo 30 10 50' run p 5 "$FRESH"
[ "$PAGES" = 1 ] && grep -q "I/O stall" "$TMP/notify.calls" && pass "P io stall alone pages once" || fail "P io-only (pages=$PAGES)"

T_GUEST='echo 2 10 91' run q 5 "$FRESH"
[ "$PAGES" = 1 ] && grep -q "root disk 91" "$TMP/notify.calls" && pass "Q guest root disk 91% >= 85: exactly one page" || { fail "Q disk (pages=$PAGES)"; cat "$TMP/log-q"; }
T_GUEST='echo 2 10 84' run r 5 "$FRESH"
[ "$PAGES" = 0 ] && pass "R guest root disk 84%: silent" || fail "R paged ($PAGES)"

# ---- U4: order of steps, evidence, verification, restart budget ----
run e4 9999 "$STALE_OK"; run e4 9999 "$STALE_OK"
seq="$(grep -nE '^(stop|start|exec .*docker run)' "$TMP/umbra.calls" | grep -v -- ' --help' | sed -E 's/^[0-9]+://' | cut -d' ' -f1-2 | tr '\n' ';')"
case "$seq" in "stop umbra-ci6;start umbra-ci6;exec umbra-ci6;"*|"stop umbra-ci6;start umbra-ci6;exec umbra-ci6;") pass "U4a order: evidence, then stop, start, then verify (docker run postgres:16-alpine)" ;; *) fail "U4a order ($seq)"; cat "$TMP/umbra.calls" ;; esac
ls "$TMP"/state-e4/umbra-ci6.evidence-*.txt >/dev/null 2>&1 && pass "U4b evidence file captured before the restart" || fail "U4b no evidence file"
grep -q "restarted and healthy" "$TMP/notify.calls" && pass "U4c Telegram summary says restarted and healthy" || fail "U4c no summary ($(cat "$TMP/notify.calls" | tr '\n' ';'))"
# budget: two restarts already in the last 24 h -> STANDDOWN, no stop/start, one page
mkdir -p "$TMP/state-e5"; printf '%s\n%s\n' "$((NOW-3*3600))" "$((NOW-9*3600))" > "$TMP/state-e5/umbra-ci6.restarts"
printf 'last_restart=%s\n' "$((NOW-8*3600))" > "$TMP/state-e5/umbra-ci6.state"
run e5 9999 "$STALE_OK"; run e5 9999 "$STALE_OK"
[ "$STOPS" = 0 ] && [ "$STARTS" = 0 ] && grep -q "budget spent" "$TMP/notify.calls" || grep -q "keeps wedging" "$TMP/notify.calls" && pass "U4d restart budget (2/24h) spent: stands down, pages a human, does NOT restart" || { fail "U4d (stops=$STOPS starts=$STARTS)"; cat "$TMP/notify.calls"; }
# older restarts do not count
mkdir -p "$TMP/state-e6"; printf '%s\n%s\n' "$((NOW-30*3600))" "$((NOW-40*3600))" > "$TMP/state-e6/umbra-ci6.restarts"
run e6 9999 "$STALE_OK"; run e6 9999 "$STALE_OK"
[ "$STOPS" = 1 ] && pass "U4e restarts older than 24 h do not use the budget" || fail "U4e (stops=$STOPS)"

# mutation control: drop the no-progress requirement from RESTART -> case C (progressing jobs) must start restarting
mkdir -p "$TMP/mutlib"; cp "$OPS"/lib/*.sh "$TMP/mutlib/"
sed 's/if \[ "\$slow" -ge 2 \] && \[ "\$np" -gt "\$GW_NOPROGRESS_MIN" \]/if [ "$slow" -ge 2 ]/' "$OPS/lib/guest-wedge.sh" > "$TMP/mutlib/guest-wedge.sh"
if cmp -s "$TMP/mutlib/guest-wedge.sh" "$OPS/lib/guest-wedge.sh"; then fail "MC mutation did not change the lib"; else
  LIBDIR="$TMP/mutlib" run m 400 "$FRESH"; LIBDIR="$TMP/mutlib" run m 400 "$FRESH"
  [ "$STOPS" = 1 ] && pass "MC without the no-progress rule a progressing slow guest WOULD be restarted (case C is a real test)" || fail "MC mutation not caught (stops=$STOPS)"
fi

echo; echo "passed=$_pass failed=$_fail"; [ "$_fail" = 0 ]
