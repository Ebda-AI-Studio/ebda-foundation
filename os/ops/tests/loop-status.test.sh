#!/usr/bin/env bash
# loop-status.sh --no-net: prints every section, exits 0, never touches the network; and the ebda-loop skill has its trigger phrases.
set -uo pipefail
cd "$(dirname "$0")/../../.." || exit 1; ROOT="$(pwd)"
_fail=0
ok() { echo "PASS: $1"; }; bad() { echo "FAIL: $1"; _fail=1; }
out="$(env PATH="/usr/bin:/bin" OS_HOME="$ROOT" OS_LOOP_AUDITS_DIR=/nonexistent bash os/ops/loop-status.sh --no-net 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "exit 0" || bad "exit $rc"
for s in "open PRs" "STILL-OPEN / FOUND" "deploy:" "alerts last 24h" "drains" "exit-check"; do
  printf '%s' "$out" | grep -qF -- "---- $s" && ok "section $s" || bad "missing section $s"
done
printf '%s' "$out" | grep -q 'skipped' && ok "net sections skipped" || bad "net not skipped"
f=os/skills/ebda-loop/SKILL.md
for p in '^name: ebda-loop$' 'run the loop' 'start the loop' 'NOT the built-in'; do grep -q -- "$p" "$f" && ok "skill has $p" || bad "skill lacks $p"; done
exit "$_fail"
