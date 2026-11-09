#!/usr/bin/env bash
. "$(dirname "$0")/assert.sh"
RT="$(dirname "$0")/../../ops/dispatch-route.sh"
OUT="$(mktemp)"
mkfake() { printf '#!/usr/bin/env bash\necho "%s $*" >> "%s"\n' "$1" "$OUT" > "$2"; chmod +x "$2"; }
D="$(mktemp -d)"; mkfake AUTOFIX "$D/af"; mkfake REMEDIATE "$D/rm"; mkfake HEAL "$D/heal"; mkfake RUNNER "$D/run"
export ROUTE_AUTOFIX="$D/af" ROUTE_REMEDIATE="$D/rm" ROUTE_HEAL="$D/heal" ROUTE_RUNNER="$D/run"
bash "$RT" ci-failure '{"slug":"o/r","sha":"s"}'
bash "$RT" code-finding '{"id":"F1"}'
bash "$RT" service-down '{"name":"api","url":"http://x"}'
bash "$RT" runner-offline '{"name":"r1"}'
assert_contains "AUTOFIX"   "$(cat "$OUT")" "ci-failure -> auto-fix"
assert_contains "REMEDIATE" "$(cat "$OUT")" "code-finding -> remediate"
assert_contains "HEAL"      "$(cat "$OUT")" "service-down -> heal"
assert_contains "RUNNER"    "$(cat "$OUT")" "runner-offline -> runner-restore"
rm -rf "$D" "$OUT"
report
