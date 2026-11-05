#!/usr/bin/env bash
# keychain_decode: hex is decoded only when the result looks like the expected secret; genuine hex tokens are left alone.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/lib/keychain.sh"
_pass=0; _fail=0
pass() { echo "PASS: $1"; _pass=$((_pass+1)); }
fail() { echo "FAIL: $1"; _fail=$((_fail+1)); }
hex() { printf '%s' "$1" | od -An -tx1 | tr -d ' \n'; }

[ "$(keychain_decode "$(hex $'line1\nline2')")" = $'line1\nline2' ] && pass "hex of a multi-line secret is decoded" || fail "multi-line"
[ "$(keychain_decode "$(hex 'AGE-SECRET-KEY-1ABCDEF')")" = "AGE-SECRET-KEY-1ABCDEF" ] && pass "hex of an age key (known prefix, no newline) is decoded" || fail "age prefix"
[ "$(keychain_decode "$(hex '-----BEGIN PRIVATE KEY-----')")" = "-----BEGIN PRIVATE KEY-----" ] && pass "hex of a PEM header is decoded" || fail "pem"
tok="$(hex 'plaintoken')"; [ "$(keychain_decode "$tok")" = "$tok" ] && pass "a genuine hex token (decodes to plain text) is left alone" || fail "plain hex"
[ "$(keychain_decode 'abc')" = "abc" ] && pass "odd-length hex-looking input is left alone" || fail "odd length"
[ "$(keychain_decode 'sk_live_XYZ')" = "sk_live_XYZ" ] && pass "non-hex secret passes through" || fail "non-hex"
[ "$(printf '%s\n' "$(hex $'a\nb')" | keychain_decode)" = $'a\nb' ] && pass "stdin form works" || fail "stdin"
[ "$(keychain_decode '  spaced out  ')" = "spaced out" ] && pass "ends trimmed, inner spaces kept" || fail "trim"
echo "keychain: $_pass passed, $_fail failed"; [ "$_fail" -eq 0 ]
