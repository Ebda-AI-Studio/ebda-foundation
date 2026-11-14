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

# no os.env reachable (library copied elsewhere): built-in defaults, never an empty identity
mkdir -p "$TMP/lonely"; cp "$ROOT/lib/os-config.sh" "$TMP/lonely/"
out="$(env -i HOME="$TMP/home" PATH="$PATH" bash -c ". '$TMP/lonely/os-config.sh' && os_config_load && echo \"\$OS_REPO_SLUG|\$OS_ORG\"")"
[ "$out" = "Ebda-AI-Studio/ebda-foundation|Ebda-AI-Studio" ] && pass "no os.env anywhere: built-in defaults apply" || fail "built-in defaults: $out"

# M-10: os_config_load must not switch off allexport for a caller that had it on (and must not leave it on for one that did not)
out="$(env -i HOME="$TMP/home" PATH="$PATH" bash -c ". '$ROOT/lib/os-config.sh'; set -a; os_config_load; case \$- in *a*) echo kept;; *) echo lost;; esac")"
[ "$out" = "kept" ] && pass "caller's set -a survives os_config_load" || fail "allexport lost: $out"
out="$(env -i HOME="$TMP/home" PATH="$PATH" bash -c ". '$ROOT/lib/os-config.sh'; os_config_load; case \$- in *a*) echo leaked;; *) echo clean;; esac")"
[ "$out" = "clean" ] && pass "allexport is not left on for a caller that had it off" || fail "allexport leaked: $out"

echo "os-config: $_pass passed, $_fail failed"; [ "$_fail" -eq 0 ]
