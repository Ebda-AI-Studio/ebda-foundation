#!/usr/bin/env bash
# sandbox.sh must REFUSE rather than silently run unconfined when it cannot
# enforce. That is the whole contract: a sandbox that quietly does nothing on the
# hosts where it is unsupported is worse than no sandbox, because it reads as one.
#
# The FUNCTIONAL Landlock proof (does a write outside the allow-list actually get
# denied?) cannot run on macOS — Landlock is a Linux LSM. It lives in
# ops/lib/__tests__/sandbox-linux.sh, run under Docker; this suite asserts the
# wrapper's fail-closed behaviour, which is testable anywhere.
# Run: bash ops/lib/__tests__/sandbox.test.sh
set -uo pipefail
LIB="$(cd "$(dirname "$0")/.." && pwd)/sandbox.sh"
_pass=0; _fail=0
ok() { echo "PASS: $1"; _pass=$((_pass+1)); }
no() { echo "FAIL: $1"; _fail=$((_fail+1)); }

H="$(mktemp -d)"
export LANDLOCK_BIN="$H/nonexistent"
# shellcheck source=/dev/null
. "$LIB"

sandbox_available && no "unavailable when the binary is missing" || ok "unavailable when the binary is missing"

out="$(sandbox_run "$H" -- /bin/echo hi 2>&1)"; rc=$?
[ "$rc" = "70" ] && ok "refuses with exit 70 when it cannot enforce" || no "refuses with exit 70 (got $rc)"
printf '%s' "$out" | grep -q "REFUSING to run unconfined" && ok "says why it refused" || no "says why it refused"
# anchored: a bare grep for "hi" also matches "this" in the refusal message,
# which made this assertion fail while the code was correct
printf '%s\n' "$out" | grep -qx "hi" && no "did NOT run the command" || ok "did NOT run the command"

# the deliberate override runs it AND announces itself
out="$(SANDBOX_ALLOW_UNCONFINED=1 sandbox_run "$H" -- /bin/echo hi 2>&1)"; rc=$?
[ "$rc" = "0" ] && ok "override runs the command" || no "override runs the command (got $rc)"
printf '%s' "$out" | grep -q "^hi$" && ok "override produced the command's output" || no "override produced the command's output"
printf '%s' "$out" | grep -q "UNCONFINED" && ok "override announces itself on stderr" || no "override announces itself on stderr"

# a stub that claims to exist but FAILS its probe must still be treated as unavailable
mkdir -p "$H/bin"; printf '#!/usr/bin/env bash\n[ "$1" = "--probe" ] && exit 1\nexit 0\n' > "$H/bin/landlock-run"
chmod +x "$H/bin/landlock-run"; export LANDLOCK_BIN="$H/bin/landlock-run"
sandbox_available && no "a binary that fails --probe is unavailable" || ok "a binary that fails --probe is unavailable"
sandbox_run "$H" -- /bin/echo hi >/dev/null 2>&1; rc=$?
[ "$rc" = "70" ] && ok "refuses when the probe fails" || no "refuses when the probe fails (got $rc)"

# no command is an argument error
sandbox_run "$H" -- >/dev/null 2>&1; rc=$?
[ "$rc" = "64" ] && ok "no command exits 64" || no "no command exits 64 (got $rc)"

rm -rf "$H"
echo; echo "sandbox: $_pass passed, $_fail failed"
[ "$_fail" -eq 0 ]
