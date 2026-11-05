#!/usr/bin/env bash
# Test job_period_seconds / job_stale_after against real plist shapes.
set -euo pipefail
. "$(dirname "$0")/../job-cadence.sh"
_pass=0; _fail=0
eq() { if [ "$2" = "$3" ]; then echo "PASS: $1"; _pass=$((_pass+1)); else echo "FAIL: $1 — got '$2' want '$3'"; _fail=$((_fail+1)); fi; }

TMP=$(mktemp -d /tmp/job-cadence-XXXXXX); trap 'rm -rf "$TMP"' EXIT

mkplist() { # mkplist <job> <inner-xml>
  cat > "$TMP/com.ebda.os.$1.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.ebda.os.$1</string>
$2
</dict></plist>
PL
}

# --- the six jobs the flat 3h window mis-healed, and the two it healed rightly ---
mkplist code-health '<key>StartCalendarInterval</key><dict><key>Hour</key><integer>6</integer><key>Minute</key><integer>0</integer><key>Weekday</key><integer>6</integer></dict>'
mkplist docs-scan   '<key>StartCalendarInterval</key><dict><key>Hour</key><integer>9</integer><key>Minute</key><integer>30</integer><key>Weekday</key><integer>0</integer></dict>'
mkplist os-selftest '<key>StartCalendarInterval</key><dict><key>Hour</key><integer>7</integer><key>Minute</key><integer>30</integer></dict>'
mkplist hourly      '<key>StartCalendarInterval</key><dict><key>Minute</key><integer>15</integer></dict>'
mkplist msg-monitor '<key>StartInterval</key><integer>1800</integer>'
mkplist deploy-drift '<key>StartInterval</key><integer>3600</integer>'

eq "weekly calendar -> 1 week"     "$(job_period_seconds code-health "$TMP")"  "604800"
eq "weekly (Sunday) -> 1 week"     "$(job_period_seconds docs-scan "$TMP")"    "604800"
eq "daily calendar -> 1 day"       "$(job_period_seconds os-selftest "$TMP")"  "86400"
eq "minute-only calendar -> 1 hour" "$(job_period_seconds hourly "$TMP")"      "3600"
eq "StartInterval passes through"  "$(job_period_seconds msg-monitor "$TMP")"  "1800"
eq "hourly interval passes through" "$(job_period_seconds deploy-drift "$TMP")" "3600"

# StartInterval governs freshness when a plist carries both.
mkplist both '<key>StartInterval</key><integer>900</integer><key>StartCalendarInterval</key><dict><key>Weekday</key><integer>1</integer></dict>'
eq "StartInterval wins over calendar" "$(job_period_seconds both "$TMP")" "900"

# Unknowable cadence must be EMPTY, never a number — a guessed period would
# licence either endless healing or none at all.
mkplist ondemand '<key>RunAtLoad</key><true/>'
eq "no schedule keys -> unknown"  "$(job_period_seconds ondemand "$TMP")" ""
eq "missing plist -> unknown"     "$(job_period_seconds nosuchjob "$TMP")" ""
eq "empty job -> unknown"         "$(job_period_seconds '' "$TMP")"       ""
eq "no args -> unknown"           "$(job_period_seconds)"                 ""

# A corrupt plist must read as UNKNOWN, not crash the caller and not guess.
printf 'not a plist at all' > "$TMP/com.ebda.os.corrupt.plist"
eq "corrupt plist -> unknown"     "$(job_period_seconds corrupt "$TMP")"  ""

# StartInterval must be a positive integer; launchd ignores the rest and so do we.
mkplist zero '<key>StartInterval</key><integer>0</integer>'
eq "StartInterval 0 -> unknown"   "$(job_period_seconds zero "$TMP")"     ""
mkplist boolint '<key>StartInterval</key><true/>'
eq "StartInterval true -> unknown" "$(job_period_seconds boolint "$TMP")" ""

# An ARRAY of calendar entries fires once per entry: 4 daily entries is a
# 6-hourly job. Treating it as daily would stop healing a job that broke.
mkplist quad '<key>StartCalendarInterval</key><array>
<dict><key>Hour</key><integer>0</integer></dict>
<dict><key>Hour</key><integer>6</integer></dict>
<dict><key>Hour</key><integer>12</integer></dict>
<dict><key>Hour</key><integer>18</integer></dict></array>'
eq "4 daily entries -> 6-hourly"  "$(job_period_seconds quad "$TMP")"     "21600"
mkplist onearr '<key>StartCalendarInterval</key><array><dict><key>Weekday</key><integer>1</integer></dict></array>'
eq "1-entry array -> weekly"      "$(job_period_seconds onearr "$TMP")"   "604800"
mkplist emptyarr '<key>StartCalendarInterval</key><array/>'
eq "empty array -> unknown"       "$(job_period_seconds emptyarr "$TMP")" ""

# BINARY plists are valid launchd input; plutil string-matching could not read
# them, plistlib can. Skip only where no converter exists (Linux CI).
if command -v plutil >/dev/null 2>&1; then
  cp "$TMP/com.ebda.os.code-health.plist" "$TMP/com.ebda.os.binfmt.plist"
  plutil -convert binary1 "$TMP/com.ebda.os.binfmt.plist" 2>/dev/null
  eq "binary plist reads"  "$(job_period_seconds binfmt "$TMP")"  "604800"
else
  echo "SKIP: binary plist (no plutil on this host)"
fi

# --- staleness windows ---
eq "weekly stales after 2 weeks"  "$(job_stale_after 604800)" "1209600"
eq "daily stales after 2 days"    "$(job_stale_after 86400)"  "172800"
eq "30-min job keeps the 3h floor" "$(job_stale_after 1800)"  "10800"
eq "1h job keeps the 3h floor"    "$(job_stale_after 3600)"   "10800"
eq "2h job crosses the floor"     "$(job_stale_after 7200)"   "14400"
eq "floor boundary (5400 -> 3h)"  "$(job_stale_after 5400)"   "10800"
eq "just past the floor"          "$(job_stale_after 5401)"   "10802"
eq "unknown period -> floor"      "$(job_stale_after '')"     "10800"
eq "garbage period -> floor"      "$(job_stale_after 'N/A')"  "10800"
eq "zero period -> floor"         "$(job_stale_after 0)"      "10800"
eq "custom floor honoured"        "$(job_stale_after 60 300)" "300"

# --- the regression this fixes, stated as the ages actually observed ---
# code-health was kickstarted at 10807s stale; a weekly job must NOT be.
w=$(job_stale_after "$(job_period_seconds code-health "$TMP")")
if [ 10807 -lt "$w" ]; then echo "PASS: 10807s does not stale a weekly job"; _pass=$((_pass+1));
else echo "FAIL: 10807s still stales a weekly job (window $w)"; _fail=$((_fail+1)); fi
# deploy-drift at 110519s stale IS genuinely broken and must still heal.
w=$(job_stale_after "$(job_period_seconds deploy-drift "$TMP")")
if [ 110519 -ge "$w" ]; then echo "PASS: 110519s still stales an hourly job"; _pass=$((_pass+1));
else echo "FAIL: hourly job stopped healing (window $w)"; _fail=$((_fail+1)); fi

# ═══════════════════════════════════════════════════════════════════════════
# job-freshness.sh — the VERDICT layer that consumes the cadence above.
#
# These live here, not in a parallel suite, because they test the same fact:
# "is this job late?". Until 2026-09-19 os-selftest.sh answered it with its OWN
# inline plist parser (Weekday -> weekly, else daily), blind to Day, Month,
# calendar ARRAYS and a bogus StartInterval — and os-selftest.test.sh "covered"
# that by REIMPLEMENTING `window = cadence*2 + 3600` in python and asserting the
# copy. Every test below drives the real shipped function instead.
# ═══════════════════════════════════════════════════════════════════════════
. "$(dirname "$0")/../job-freshness.sh"
# Pin the host's last-wake time so no verdict below depends on when THIS machine
# last slept (the sleep-tolerance cases further down override it explicitly).
export JF_WAKE_EPOCH_OVERRIDE=0

STATED="$TMP/state"; mkdir -p "$STATED"
NOW=$(date +%s)

# age_file <path> <seconds-ago> — control mtime so "now" is deterministic.
age_file() {
  AF_P="$1" AF_A="$2" python3 -c '
import os, time
p = os.environ["AF_P"]; t = time.time() - int(os.environ["AF_A"])
os.utime(p, (t, t))'
}
mklog() { printf 'x\n' > "$1"; age_file "$1" "$2"; }
# verdict <job> -> just the verdict word
verdict() { job_freshness_verdict "$TMP/com.ebda.os.$1.plist" "$NOW" "$STATED" "$TMP" | cut -d'|' -f1; }
# vfield <job> <n> -> the nth pipe field of the raw verdict
vfield() { job_freshness_verdict "$TMP/com.ebda.os.$1.plist" "$NOW" "$STATED" "$TMP" | cut -d'|' -f"$2"; }

# --- (a) a MONTHLY job (Day=1) is not stale ---------------------------------
# session-mining is Day=1. The old parser saw no Weekday, called it DAILY, and
# would have reported it stale every single day from its first run onward.
mkplist monthly "<key>StartCalendarInterval</key><dict><key>Day</key><integer>1</integer><key>Hour</key><integer>5</integer></dict><key>StandardOutPath</key><string>$TMP/monthly.log</string>"
mklog "$TMP/monthly.log" 108000          # 30 HOURS old
eq "monthly job fresh at 30h"      "$(verdict monthly)" "fresh"
mklog "$TMP/monthly.log" 2592000         # 30 DAYS old — inside a monthly cadence
eq "monthly job fresh at 30d"      "$(verdict monthly)" "fresh"
eq "monthly window is 2 months"    "$(vfield monthly 3)" "5184000"
mklog "$TMP/monthly.log" 9000000         # 104 days — genuinely stopped
eq "monthly job stale at 104d"     "$(verdict monthly)" "stale"

# --- (b) a WEEKLY job (Weekday=0) is not stale mid-week ---------------------
mkplist sunday "<key>StartCalendarInterval</key><dict><key>Weekday</key><integer>0</integer><key>Hour</key><integer>9</integer></dict><key>StandardOutPath</key><string>$TMP/sunday.log</string>"
mklog "$TMP/sunday.log" 345600           # 4 days — mid-week, idle on purpose
eq "weekly job fresh mid-week"     "$(verdict sunday)" "fresh"
mklog "$TMP/sunday.log" 1900000          # 22 days — three missed Sundays
eq "weekly job stale at 22d"       "$(verdict sunday)" "stale"

# --- (c) heal-watch: 35h-old launchd stream, FRESH state log ---------------
# The single FAIL in the live self-test on 2026-09-19. heal-watch runs every
# 180s and writes ~/.whisky-os-state/heal.log on EVERY pass (verified: 100 of
# the last 100 lines are run summaries), but only echoes to its launchd stream
# when it has something to say — so the stream log was 35h old and the job was
# reported stale while running perfectly.
mkplist heal-watch "<key>StartInterval</key><integer>180</integer><key>StandardOutPath</key><string>$TMP/heal-stream.log</string>"
mklog "$TMP/heal-stream.log" 126000      # 35h — the misleading artifact
mklog "$STATED/heal.log" 60              # the authoritative one, fresh
eq "heal-watch fresh via state log" "$(verdict heal-watch)" "fresh"
eq "heal-watch reads the STATE log"  "$(vfield heal-watch 5)" "$STATED/heal.log"
# The allowlist must not hide a genuinely dead heal-watch.
mklog "$STATED/heal.log" 200000
eq "heal-watch still stales when its state log dies" "$(verdict heal-watch)" "stale"
mklog "$STATED/heal.log" 60
# gate-guard keeps the same treatment it already had.
mkplist gate-guard "<key>StartCalendarInterval</key><dict><key>Hour</key><integer>6</integer></dict><key>StandardOutPath</key><string>$TMP/gg-stream.log</string>"
mklog "$TMP/gg-stream.log" 2200000
mklog "$STATED/gate-guard.log" 3305
eq "gate-guard fresh via state log" "$(verdict gate-guard)" "fresh"
# A job NOT on the allowlist must never be given a state log by guessing — that
# swap previously traded one false stale for two others.
mkplist app-error-heal "<key>StartInterval</key><integer>3600</integer><key>StandardOutPath</key><string>$TMP/aeh.log</string>"
mklog "$TMP/aeh.log" 200
mklog "$STATED/app-error-heal.log" 999999
eq "non-allowlisted job uses its own stream log" "$(vfield app-error-heal 5)" "$TMP/aeh.log"

# --- (c2) host sleep: quiet-when-healthy jobs must not read stale after waking
# #197: heal-watch (180s cadence, 3h window) and gate-guard were reported stale at
# the self-test that ran right after the Mac woke from a long sleep. launchd's
# StartInterval does not count sleep time, so the job is simply not due again yet.
mklog "$STATED/heal.log" 40000                 # ~11h old: far outside the 3h window
WAKE=$((NOW - 120))                            # host woke 2 minutes ago
eq "heal-watch stale by clock, host woke 2m ago -> slept (tolerated)" \
   "$(JF_WAKE_EPOCH_OVERRIDE=$WAKE verdict heal-watch)" "slept"
eq "no wake info (0) -> strict stale verdict stands" "$(JF_WAKE_EPOCH_OVERRIDE=0 verdict heal-watch)" "stale"
WAKE=$((NOW - 3600))                           # woke 1h ago: > one 180s period + 10m slack
eq "woke 1h ago and STILL no write -> stale (a dead job is not excused forever)" \
   "$(JF_WAKE_EPOCH_OVERRIDE=$WAKE verdict heal-watch)" "stale"
WAKE=$((NOW - 30000))                          # woke BEFORE the last write: sleep explains nothing
eq "log written after the wake and still old -> stale" \
   "$(JF_WAKE_EPOCH_OVERRIDE=$WAKE verdict heal-watch)" "stale"
mklog "$STATED/gate-guard.log" 400000          # ~4.6d old, outside gate-guard's window
eq "gate-guard stale by clock, host woke 5m ago -> slept (tolerated)" \
   "$(JF_WAKE_EPOCH_OVERRIDE=$((NOW - 300)) verdict gate-guard)" "slept"
mklog "$STATED/heal.log" 60
mklog "$STATED/gate-guard.log" 3305

# --- (d) a genuinely stopped DAILY job is stale -----------------------------
mkplist daily-dead "<key>StartCalendarInterval</key><dict><key>Hour</key><integer>7</integer><key>Minute</key><integer>30</integer></dict><key>StandardOutPath</key><string>$TMP/dead.log</string>"
mklog "$TMP/dead.log" 432000             # 5 days
eq "stopped daily job is stale"    "$(verdict daily-dead)" "stale"
mklog "$TMP/dead.log" 90000              # 25h — one late run, not a failure
eq "daily job late by 1h is fresh" "$(verdict daily-dead)" "fresh"

# --- (e) no artifact AND no schedule must FAIL, never silently pass ---------
# The whole point of the fix: "nothing to check" and "checked, fine" are
# different answers, and only one of them is true.
mkplist orphan '<key>ProgramArguments</key><array><string>/bin/true</string></array>'
eq "no cadence + no artifact -> unprovable" "$(verdict orphan)" "unprovable"
mkplist noout '<key>StartInterval</key><integer>900</integer>'
eq "schedule but no log path -> unprovable" "$(verdict noout)" "unprovable"
# A bogus StartInterval is a config defect, not a licence to assume "daily".
mkplist zeroiv "<key>StartInterval</key><integer>0</integer><key>StandardOutPath</key><string>$TMP/zero.log</string>"
mklog "$TMP/zero.log" 60
eq "StartInterval 0 -> unprovable, not assumed daily" "$(verdict zeroiv)" "unprovable"

# --- (f) a KeepAlive daemon is judged by PROCESS LIVENESS -------------------
# Its log mtime is evidence of nothing: a healthy resident process can sit
# silent for weeks, and a dead one leaves a log that simply stops changing.
mkplist daemon1 "<key>KeepAlive</key><true/><key>RunAtLoad</key><true/><key>StandardOutPath</key><string>$TMP/daemon1.log</string>"
mklog "$TMP/daemon1.log" 9000000         # ancient, and irrelevant
eq "live daemon -> daemon-running"   "$(JF_LAUNCHCTL_OVERRIDE=running verdict daemon1)" "daemon-running"
eq "dead daemon -> daemon-stopped"   "$(JF_LAUNCHCTL_OVERRIDE=loaded  verdict daemon1)" "daemon-stopped"
eq "absent daemon -> daemon-stopped" "$(JF_LAUNCHCTL_OVERRIDE=absent  verdict daemon1)" "daemon-stopped"
eq "no launchctl -> unprovable, not a pass" "$(JF_LAUNCHCTL_OVERRIDE=unknown verdict daemon1)" "daemon-unprovable"
# umbrad's shape: KeepAlive is a DICT, not a bool.
mkplist daemon2 '<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>'
eq "dict KeepAlive is still a daemon" "$(JF_LAUNCHCTL_OVERRIDE=running verdict daemon2)" "daemon-running"
# A job with BOTH a schedule and RunAtLoad is scheduled, not a daemon.
mkplist sched-runatload "<key>RunAtLoad</key><true/><key>StartInterval</key><integer>600</integer><key>StandardOutPath</key><string>$TMP/sr.log</string>"
mklog "$TMP/sr.log" 120
eq "schedule+RunAtLoad is scheduled, not daemon" "$(verdict sched-runatload)" "fresh"

# --- backup jobs keep their pinned 36h window -------------------------------
# A missed backup is a DR gap on the FIRST night. The generic rule would give a
# daily job 48h and let one missed night pass unremarked until the night after.
mkplist ebda-cf-backup "<key>StartCalendarInterval</key><dict><key>Hour</key><integer>3</integer><key>Minute</key><integer>30</integer></dict><key>StandardOutPath</key><string>$TMP/neon.log</string>"
mklog "$TMP/neon.log" 108000             # 30h
eq "backup fresh at 30h"           "$(verdict ebda-cf-backup)" "fresh"
eq "backup window is pinned to 36h" "$(vfield ebda-cf-backup 3)" "129600"
mklog "$TMP/neon.log" 144000             # 40h — inside 48h, outside 36h
eq "backup stale at 40h (36h window)" "$(verdict ebda-cf-backup)" "stale"

# --- an ARRAY of calendar entries divides the period ------------------------
mkplist quadjob "<key>StartCalendarInterval</key><array>
<dict><key>Hour</key><integer>0</integer></dict>
<dict><key>Hour</key><integer>6</integer></dict>
<dict><key>Hour</key><integer>12</integer></dict>
<dict><key>Hour</key><integer>18</integer></dict></array><key>StandardOutPath</key><string>$TMP/quad.log</string>"
mklog "$TMP/quad.log" 30000
eq "6-hourly array job fresh at 8h"  "$(verdict quadjob)" "fresh"
mklog "$TMP/quad.log" 50000
eq "6-hourly array job stale at 14h" "$(verdict quadjob)" "stale"

# --- a missing log: awaiting-first-run vs never-ran vs not-loaded -----------
# launchd creates StandardOutPath when it spawns a job, so an absent file means
# the job has not run since that path was set — EXCEPT that a job cannot be late
# before its first slot has come round.
mkplist newmonthly "<key>StartCalendarInterval</key><dict><key>Day</key><integer>1</integer></dict><key>StandardOutPath</key><string>$TMP/nm.log</string>"
eq "fresh plist, monthly, no log -> awaiting-first-run" \
   "$(JF_LAUNCHCTL_OVERRIDE=loaded verdict newmonthly)" "awaiting-first-run"
# Once the plist outlives a full period the suppression stops on its own, so a
# monthly job that genuinely died is still caught.
age_file "$TMP/com.ebda.os.newmonthly.plist" 4000000
eq "aged plist, monthly, no log -> never-ran" \
   "$(JF_LAUNCHCTL_OVERRIDE=loaded verdict newmonthly)" "never-ran"
eq "aged plist, no log, unloaded -> not-loaded" \
   "$(JF_LAUNCHCTL_OVERRIDE=absent verdict newmonthly)" "not-loaded"

# --- a corrupt or missing plist is UNKNOWN, never a pass --------------------
printf 'not a plist' > "$TMP/com.ebda.os.brokenfresh.plist"
eq "corrupt plist -> unparseable"  "$(verdict brokenfresh)" "unparseable"
eq "missing plist -> unparseable"  "$(verdict nosuchjobatall)" "unparseable"

echo; echo "$_pass passed, $_fail failed"; [ "$_fail" -eq 0 ]
