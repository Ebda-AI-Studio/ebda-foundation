#!/usr/bin/env bash
# drift-watch.sh reads the OS from $OS_HOME/os (os/ops + os/launchd/mac-local.list). Before 2026-11-10 it looked for $OS_HOME/ops,
# which does not exist in ebda-foundation, so every run exited 0 at "ops dir missing" (a silently dead watcher). Must fire: a
# Mac-local job that is not installed is reported. Must not fire: a template NOT in mac-local.list is not reported.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1; OPS="$(pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
_pass=0; _fail=0
pass() { echo "PASS: $1"; _pass=$((_pass+1)); }
fail() { echo "FAIL: $1"; _fail=$((_fail+1)); }
F="$T/fdn"; mkdir -p "$F/os/ops/launchd" "$F/os/launchd" "$T/home/.claude/scripts" "$T/home/Library/LaunchAgents" "$T/home/Desktop/projects/Ebda-AI-Studio/internal-projects/ebda-store/.git" "$T/state"
printf '<plist><string>com.ebda.os.wanted</string></plist>\n' > "$F/os/ops/launchd/com.ebda.os.wanted.plist"
printf '<plist><string>com.ebda.os.brainjob</string></plist>\n' > "$F/os/ops/launchd/com.ebda.os.brainjob.plist"
printf 'wanted\tops/launchd/com.ebda.os.wanted.plist\n' > "$F/os/launchd/mac-local.list"
env HOME="$T/home" OS_STATE_DIR="$T/state" OS_PROJECTS_DIR="$T/home/Desktop/projects" OS_ORGS=Ebda-AI-Studio OS_HOME="$F" OS_LAUNCHD_PREFIX=com.ebda.os EBDA_OS_LOCAL_ENV="$T/none.env" bash "$OPS/drift-watch.sh" >"$T/out" 2>&1
grep -q 'ops dir missing' "$T/out" && fail "still looks for \$OS_HOME/ops" || pass "reads \$OS_HOME/os/ops"
grep -q 'PLIST-MISSING: com.ebda.os.wanted' "$T/out" && pass "a Mac-local job that is not installed is reported (must fire)" || { fail "missing wanted not reported"; cat "$T/out"; }
grep -q 'com.ebda.os.brainjob' "$T/out" && fail "a brain-run template was reported missing" || pass "templates outside mac-local.list are not expected (must not fire)"
# INSTALL-1: an opt-in job (3rd column optin=VAR) is expected only when VAR=1, and the flag column is not read as part of the path
printf '<plist><string>com.ebda.os.optjob</string></plist>\n' > "$F/os/ops/launchd/com.ebda.os.optjob.plist"
printf 'optjob\tops/launchd/com.ebda.os.optjob.plist\toptin=OS_OPT_TEST\n' >> "$F/os/launchd/mac-local.list"
run_dw() { env HOME="$T/home" OS_STATE_DIR="$T/state" OS_PROJECTS_DIR="$T/home/Desktop/projects" OS_ORGS=Ebda-AI-Studio OS_HOME="$F" OS_LAUNCHD_PREFIX=com.ebda.os EBDA_OS_LOCAL_ENV="$T/none.env" "$@" bash "$OPS/drift-watch.sh" >"$T/out2" 2>&1; }
run_dw
grep -q 'com.ebda.os.optjob' "$T/out2" && fail "opt-in job reported although not opted in" || pass "opt-in job not expected without its flag (must not fire)"
grep -q 'TEMPLATE-MISSING' "$T/out2" && fail "flag column read as part of the template path" || pass "flag column is not part of the template path"
run_dw OS_OPT_TEST=1
grep -q 'PLIST-MISSING: com.ebda.os.optjob' "$T/out2" && pass "opted-in job that is not installed is reported (must fire)" || { fail "opted-in job not reported"; cat "$T/out2"; }
echo "drift-watch-paths: $_pass passed, $_fail failed"
[ "$_fail" = 0 ]
