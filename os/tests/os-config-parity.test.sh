#!/usr/bin/env bash
# os/config/os.env and the built-in defaults inside ops/lib/os-config.sh must define identical values for every OS_* key.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home" "$TMP/lonely"; cp "$ROOT/os/ops/lib/os-config.sh" "$TMP/lonely/"
dump() { env -i HOME="$TMP/home" PATH="$PATH" bash -c ". '$1' && os_config_load && env | grep '^OS_' | LC_ALL=C sort"; }
a="$(dump "$ROOT/os/ops/lib/os-config.sh")"       # finds os/config/os.env
b="$(dump "$TMP/lonely/os-config.sh")"             # built-ins only
keys_env="$(grep -oE '^OS_[A-Z_]+=' "$ROOT/os/config/os.env" | sort -u | tr -d '=' | tr '\n' ' ')"
keys_lib="$(printf '%s\n' "$a" | cut -d= -f1 | grep -vE '^OS_(ORG|VM|BILLED_ORGS)$' | sort -u | tr '\n' ' ')"
rc=0
if [ "$a" = "$b" ]; then echo "PASS: os.env and the built-in defaults agree ($(printf '%s\n' "$a" | wc -l | tr -d ' ') keys)"; else echo "FAIL: os.env vs built-ins differ:"; diff <(printf '%s\n' "$a") <(printf '%s\n' "$b"); rc=1; fi
if [ "$keys_env" = "$keys_lib" ]; then echo "PASS: every key in os.env is exported by os_config_load"; else echo "FAIL: key sets differ: env=[$keys_env] lib=[$keys_lib]"; rc=1; fi
exit "$rc"
