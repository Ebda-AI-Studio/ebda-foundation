#!/usr/bin/env bash
# os_config_load: os.env defaults, the per-machine override file wins, a missing os.env fails loudly.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
_pass=0; _fail=0
pass() { echo "PASS: $1"; _pass=$((_pass+1)); }
fail() { echo "FAIL: $1"; _fail=$((_fail+1)); }
run() { env -i HOME="$TMP/home" PATH="$PATH" "$@" bash -c ". '$ROOT/lib/os-config.sh' && os_config_load && $CMD"; }
mkdir -p "$TMP/home"

CMD='echo "$OS_REPO_SLUG|$OS_LAUNCHD_PREFIX|$OS_GIT_CHAIN_KEY"'
out="$(run)"; [ "$out" = "Ebda-AI-Studio/ebda-foundation|com.ebda.os|ebda.chainHusky" ] && pass "defaults come from os/config/os.env" || fail "defaults: $out"

printf 'OS_LAUNCHD_PREFIX=com.example.local\n' > "$TMP/local.env"
out="$(run EBDA_OS_LOCAL_ENV="$TMP/local.env")"; case "$out" in *"|com.example.local|"*) pass "~/.ebda-os.local.env overrides os.env" ;; *) fail "override: $out" ;; esac

CMD='echo "$OS_ORGS"'
out="$(run)"; [ "$out" = "Ebda-AI-Studio Whisky-11 voidengineer-911" ] && pass "OS_ORGS exported with all three owners" || fail "orgs: $out"

out="$(env -i HOME="$TMP/home" PATH="$PATH" OS_CONFIG_FILE="$TMP/nope.env" bash -c ". '$ROOT/lib/os-config.sh'; cp -r '$ROOT/lib' '$TMP/lib2'; . '$TMP/lib2/os-config.sh'; os_config_load" 2>&1)"; rc=$?
echo "(missing-os.env case rc=$rc)" >/dev/null
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'no os.env found'; then pass "no os.env anywhere: fails loudly"; else fail "missing os.env: rc=$rc out=$out"; fi

echo "os-config: $_pass passed, $_fail failed"; [ "$_fail" -eq 0 ]
