#!/usr/bin/env bash
# F-06 / F-06b for the Mac runner: it refuses to claim when ANY Claude-credential variable is in its environment (the hands' API key lives in
# the container only), needs its OWN bearer (HANDS_MAC_TOKEN, never the container's HANDS_TOKEN), and starts node only when clean.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SH="$HERE/../../cloud/hands/providers/mac-local.sh"
pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1 - got '$2' want '$3'"; fail=$((fail+1)); fi; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/home"
printf '#!/bin/sh\necho "node $*" >> "%s/node.log"\n' "$TMP" > "$TMP/bin/node"; chmod +x "$TMP/bin/node"
echo '{"repos":{}}' > "$TMP/hands.json"
run() {  # $1 = services env content
  printf '%s\n' "$1" > "$TMP/services.env"; : > "$TMP/node.log"
  env -i HOME="$TMP/home" PATH="$TMP/bin:/usr/bin:/bin" OS_SERVICES_ENV="$TMP/services.env" HANDS_CONFIG_FILE="$TMP/hands.json" OS_STATE_DIR="$TMP/state" EBDA_OS_LOCAL_ENV="$TMP/none.env" bash "$SH" >"$TMP/out" 2>&1; echo $?
}
CLEAN=$'BRAIN_URL=https://b.test\nHANDS_MAC_TOKEN=m\nGH_TOKEN=g\nHANDS_GIT_NAME=n\nHANDS_GIT_EMAIL=e@x'
ok "clean env: node starts the claim (exit 0)"            "$(run "$CLEAN")" "0"
ok "  ...with --claim"                                   "$(grep -c -- '--claim' "$TMP/node.log")" "1"
for k in ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CODE_USE_BEDROCK AWS_BEARER_TOKEN_BEDROCK; do
  ok "$k in the services env: refused with exit 4"       "$(run "$CLEAN"$'\n'"$k=x")" "4"
  ok "  ...node never started"                           "$(wc -l < "$TMP/node.log" | tr -d ' ')" "0"
done
ok "another vendor's key (GEMINI_API_KEY) does not stop it" "$(run "$CLEAN"$'\nGEMINI_API_KEY=x')" "0"
ok "no HANDS_MAC_TOKEN (only the container token): nothing claimed" "$(run $'BRAIN_URL=https://b.test\nHANDS_TOKEN=t\nGH_TOKEN=g\nHANDS_GIT_NAME=n\nHANDS_GIT_EMAIL=e@x')$(wc -l < "$TMP/node.log" | tr -d ' ')" "00"
echo "---"; echo "hands-mac-local: $pass passed, $fail failed"; [ "$fail" = 0 ]
