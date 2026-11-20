#!/usr/bin/env bash
# dead-gate-detect: the four 2026-11-20 false positives are skipped, a REAL missing binary is still reported.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; OPS="$(cd "$HERE/.." && pwd)"
pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1 - got '$2' want '$3'"; fail=$((fail+1)); fi; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME/.claude" "$TMP/root/tests" "$TMP/root/_retired-x"
echo '{"hooks":{}}' > "$HOME/.claude/settings.json"
export OS_HOME=/nonexistent DEAD_GATE_ROOT="$TMP/root"
run() { bash "$OPS/dead-gate-detect.sh" 2>&1; }

# 1. elif fallback after an installed tool (host-lock shape)
cat > "$TMP/root/lock.sh" <<'EOS'
if command -v sh >/dev/null 2>&1; then
  echo a
elif command -v nosuchtool-flock >/dev/null 2>&1; then
  echo b
fi
EOS
# 2. function from a sourced lib
echo 'if ! command -v backup_thing_entries >/dev/null 2>&1; then echo x; fi' > "$TMP/root/fn.sh"
# 3. tests/ fixture asserting absence
printf '%s\n' "{ cat x; echo 'D=\$(command -v nosuchtool-gdate || echo date)'; } > m" > "$TMP/root/tests/t.sh"
# 4. retired dir
echo 'command -v nosuchtool-umbra >/dev/null || exit 1' > "$TMP/root/_retired-x/r.sh"
out="$(run)"; ok "1-4 all four false-positive shapes -> clean run reports 0" "$(echo "$out" | grep -c 'MISSING\|nosuchtool')/$(echo "$out" | grep -c 'OK')" "0/1"

# 5. a REAL missing binary is still caught (plain script, plain guard)
echo 'if command -v nosuchtool-real >/dev/null 2>&1; then echo y; fi' > "$TMP/root/real.sh"
out="$(run)"; ok "5 real missing binary still reported" "$(echo "$out" | grep -c 'nosuchtool-real')" "1"
# 6. an elif whose EARLIER branch is also missing is still caught
echo 'if command -v nosuchtool-a; then :; elif command -v nosuchtool-b; then :; fi' > "$TMP/root/real2.sh"
out="$(run)"; ok "6 elif chain with NO installed branch still reported" "$(echo "$out" | grep -c 'nosuchtool-b')" "1"
# 7. same shape under tests/ but not an echo line is still caught
echo 'command -v nosuchtool-intests || true' > "$TMP/root/tests/u.sh"
out="$(run)"; ok "7 non-echo guard inside tests/ still reported" "$(echo "$out" | grep -c 'nosuchtool-intests')" "1"
echo; echo "passed=$pass failed=$fail"; [ "$fail" = 0 ]
