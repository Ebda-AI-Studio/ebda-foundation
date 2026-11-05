#!/usr/bin/env bash
# check-provenance.sh must FAIL when a scrubbed client name is present and when a
# manifest row has no real commit. An unfailable provenance gate is worse than
# none: it certifies a boundary it never checked.
# Run: bash ops/lib/__tests__/check-provenance.test.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/check-provenance.sh"
TEMPLATE="$(cd "$ROOT/.." && pwd)/template/VENDOR-PROVENANCE.md"
_pass=0; _fail=0
ok() { echo "PASS: $1"; _pass=$((_pass+1)); }
no() { echo "FAIL: $1"; _fail=$((_fail+1)); }
saw() { printf '%s' "$2" | grep -q "$1"; }

mkrepo() {                 # $1 = dir, $2 = upstream sha for the manifest row
  mkdir -p "$1/src"
  echo "export const x = 1;" > "$1/src/index.ts"
  sed "s/0000000000000000000000000000000000000000/$2/" "$TEMPLATE" > "$1/VENDOR-PROVENANCE.md"
  git -C "$1" init -q
  git -C "$1" -c user.email=t@t -c user.name=t add -A >/dev/null
  git -C "$1" -c user.email=t@t -c user.name=t commit -qm init
}

SHA="1234567890abcdef1234567890abcdef12345678"

# --- clean ---
R="$(mktemp -d)"; mkrepo "$R" "$SHA"
bash "$SCRIPT" --repo "$R" >/dev/null 2>&1 && ok "a filled-in manifest with a clean tree passes" || no "a filled-in manifest with a clean tree passes"
rm -rf "$R"

# --- the template's all-zero placeholder must NOT pass ---
R="$(mktemp -d)"; mkrepo "$R" "0000000000000000000000000000000000000000"
out="$(bash "$SCRIPT" --repo "$R" 2>&1 || true)"
saw "all-zero template placeholder" "$out" && ok "the unfilled template placeholder is caught" || no "the unfilled template placeholder is caught"
bash "$SCRIPT" --repo "$R" >/dev/null 2>&1 && no "placeholder fails the gate" || ok "placeholder fails the gate"
rm -rf "$R"

# --- a tag instead of a commit is not provenance ---
R="$(mktemp -d)"; mkrepo "$R" "v1.4.2"
bash "$SCRIPT" --repo "$R" >/dev/null 2>&1 && no "a tag instead of a SHA fails" || ok "a tag instead of a SHA fails"
rm -rf "$R"

# --- a scrubbed CLIENT NAME anywhere in the tree fails ---
R="$(mktemp -d)"; mkrepo "$R" "$SHA"
echo 'const store = "acme-client";' > "$R/src/leak.ts"
git -C "$R" -c user.email=t@t -c user.name=t add -A >/dev/null
git -C "$R" -c user.email=t@t -c user.name=t commit -qm leak
out="$(bash "$SCRIPT" --repo "$R" 2>&1 || true)"
saw "scrub violation" "$out" && ok "a leaked client name is reported" || no "a leaked client name is reported"
saw "src/leak.ts" "$out" && ok "names the offending file" || no "names the offending file"
bash "$SCRIPT" --repo "$R" >/dev/null 2>&1 && no "a leaked client name fails the gate" || ok "a leaked client name fails the gate"
rm -rf "$R"

# --- a leaked DOMAIN also fails (different scrub class) ---
R="$(mktemp -d)"; mkrepo "$R" "$SHA"
echo 'const api = "https://acme.example/api";' > "$R/src/leak.ts"
git -C "$R" -c user.email=t@t -c user.name=t add -A >/dev/null
git -C "$R" -c user.email=t@t -c user.name=t commit -qm leak
bash "$SCRIPT" --repo "$R" >/dev/null 2>&1 && no "a leaked domain fails the gate" || ok "a leaked domain fails the gate"
rm -rf "$R"

# --- the provenance file itself is exempt (it LISTS the patterns) ---
R="$(mktemp -d)"; mkrepo "$R" "$SHA"
bash "$SCRIPT" --repo "$R" >/dev/null 2>&1 && ok "the provenance file's own scrub table is not a violation" || no "the provenance file's own scrub table is not a violation"
rm -rf "$R"

# --- a MISSING provenance file is exit 2, not a pass ---
R="$(mktemp -d)"; mkdir -p "$R/src"; git -C "$R" init -q
bash "$SCRIPT" --repo "$R" >/dev/null 2>&1; rc=$?
[ "$rc" = "2" ] && ok "a missing manifest exits 2" || no "a missing manifest exits 2 (got $rc)"
rm -rf "$R"

echo; echo "check-provenance: $_pass passed, $_fail failed"
[ "$_fail" -eq 0 ]
