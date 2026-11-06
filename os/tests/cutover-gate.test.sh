#!/usr/bin/env bash
# ops/cutover-gate-check.sh: blocks on missing rows, missing brain watchers, missing replacements, unlisted KEEP-MAC, bare DROP; clears when all satisfied.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; G="$ROOT/os/ops/cutover-gate-check.sh"
fail=0; ok() { echo "PASS: $1"; }; no() { echo "FAIL: $1"; fail=1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk() { # fresh fixture tree
  rm -rf "$T/r"; mkdir -p "$T/r/os/ops/launchd" "$T/r/os/launchd" "$T/r/os/cloud/brain/src/watchers"
  : > "$T/r/os/ops/launchd/com.ebda.os.alpha.plist"; : > "$T/r/os/ops/launchd/com.ebda.os.beta.plist"
  printf 'gamma\n' > "$T/r/os/launchd/unported-jobs.list"
  printf 'alpha\tops/launchd/com.ebda.os.alpha.plist\n' > "$T/r/os/launchd/mac-local.list"
  : > "$T/r/os/cloud/brain/src/watchers/beta-w.ts"
  cat > "$T/r/os/MANIFEST.md" <<'M'
## Old-job dispositions

| Job | Disposition | Detail | Reason |
|---|---|---|---|
| alpha | KEEP-MAC | alpha | needs umbra |
| beta | PORT-BRAIN | beta-w | http poll |
| gamma | DROP | - | obsolete |
M
}
mk; out="$(bash "$G" --root "$T/r")"; rc=$?; [ "$rc" = 0 ] && ok "complete fixture clears (exit 0)" || { no "fixture should clear"; echo "$out"; }
mk; rm "$T/r/os/cloud/brain/src/watchers/beta-w.ts"; out="$(bash "$G" --root "$T/r")"; rc=$?
{ [ "$rc" = 1 ] && printf '%s' "$out" | grep -q "beta: PORT-BRAIN watcher 'beta-w' missing"; } && ok "missing brain watcher blocks and is listed" || no "missing watcher not caught"
mk; sed -i.bak '/| gamma |/d' "$T/r/os/MANIFEST.md"; out="$(bash "$G" --root "$T/r")"; rc=$?
{ [ "$rc" = 1 ] && printf '%s' "$out" | grep -q "old job 'gamma' has no disposition row"; } && ok "old job without a row blocks" || no "missing row not caught"
mk; : > "$T/r/os/ops/launchd/com.ebda.os.delta.plist"; out="$(bash "$G" --root "$T/r")"; rc=$?
{ [ "$rc" = 1 ] && printf '%s' "$out" | grep -q "'delta' has no disposition row"; } && ok "new plist with no row blocks" || no "new plist not caught"
mk; : > "$T/r/os/launchd/mac-local.list"; out="$(bash "$G" --root "$T/r")"; rc=$?
{ [ "$rc" = 1 ] && printf '%s' "$out" | grep -q "alpha: KEEP-MAC but 'alpha' is not in"; } && ok "KEEP-MAC not installed blocks" || no "unlisted KEEP-MAC not caught"
mk; sed -i.bak 's/| gamma | DROP | - | obsolete |/| gamma | DROP | - | - |/' "$T/r/os/MANIFEST.md"; out="$(bash "$G" --root "$T/r")"; rc=$?
{ [ "$rc" = 1 ] && printf '%s' "$out" | grep -q "gamma: DROP without a reason"; } && ok "DROP without a reason blocks" || no "bare DROP not caught"
# the real repo: every old job has a row (the only blockers allowed are missing implementations)
out="$(bash "$G")"; printf '%s' "$out" | grep -q "has no disposition row" && no "real MANIFEST misses a job row" || ok "real MANIFEST has a row for every old job"
[ "$fail" = 0 ] && echo "cutover-gate: PASS" || echo "cutover-gate: FAIL"; exit "$fail"
