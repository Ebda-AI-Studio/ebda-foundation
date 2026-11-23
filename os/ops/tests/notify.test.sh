#!/usr/bin/env bash
# notify.sh credential order + fallback, with stub curl / security / brain-send (never touches the real Keychain or Telegram):
# env > Keychain > services env; Bot API not ok -> brain fallback; both fail -> exit 1 loud; the token never appears in output.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
N="$ROOT/os/ops/notify.sh"
p=0; f=0; ok() { echo "PASS: $1"; p=$((p+1)); }; no() { echo "FAIL: $1"; f=$((f+1)); }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/home" "$T/ops"
cp "$N" "$T/ops/notify.sh"; mkdir -p "$T/ops/lib"   # no os-config here: notify must not need it
export HOME="$T/home" PATH="$T/bin:/usr/bin:/bin" OS_SERVICES_ENV="$T/none.env" EBDA_OS_LOCAL_ENV="$T/none.local"
cat > "$T/bin/security" <<'S'
#!/bin/bash
case "$*" in *ebda-telegram-bot*) [ -n "${KC_TOKEN:-}" ] && echo "$KC_TOKEN" || exit 44 ;; *ebda-telegram-alert-chat-id*) [ -n "${KC_CHAT:-}" ] && echo "$KC_CHAT" || exit 44 ;; esac
S
cat > "$T/bin/curl" <<'S'
#!/bin/bash
# records the url from the -K config file, answers per API_OK
cfg=""; while [ $# -gt 0 ]; do [ "$1" = -K ] && cfg="$2"; shift; done
sed -n 's/^url = "\(.*\)"/\1/p' "$cfg" > "$CURL_URL"
[ "${API_OK:-1}" = 1 ] && echo '{"ok":true,"result":{}}' || echo '{"ok":false,"error_code":401}'
S
cat > "$T/ops/brain-send.sh" <<'S'
#!/bin/bash
[ -n "${BRAIN_FAIL:-}" ] && exit 1; echo "brain: $*" >> "$BRAIN_LOG"
S
chmod +x "$T/bin/security" "$T/bin/curl" "$T/ops/brain-send.sh"
export CURL_URL="$T/url" BRAIN_LOG="$T/brain.log"
run() { bash "$T/ops/notify.sh" "$@" 2>&1; }
reset() { rm -f "$CURL_URL" "$BRAIN_LOG"; unset KC_TOKEN KC_CHAT API_OK BRAIN_FAIL TELEGRAM_BOT_TOKEN TELEGRAM_ALERT_CHAT_ID; }

reset; KC_TOKEN=111:kctoken KC_CHAT=42 out="$(KC_TOKEN=111:kctoken KC_CHAT=42 run T b)"; rc=$?
[ $rc = 0 ] && grep -q "bot111:kctoken" "$CURL_URL" && ok "token + chat id read from the Keychain" || no "keychain path ($out)"
printf '%s' "$out" | grep -q kctoken && no "token leaked into output" || ok "token never printed"
reset; out="$(TELEGRAM_BOT_TOKEN=222:envtoken TELEGRAM_ALERT_CHAT_ID=1 KC_TOKEN=111:kctoken KC_CHAT=42 run T b)"
grep -q "bot222:envtoken" "$CURL_URL" && ok "environment beats the Keychain" || no "env precedence"
reset; printf 'TELEGRAM_BOT_TOKEN=333:svctoken\nTELEGRAM_ALERT_CHAT_ID=7\n' > "$T/svc.env"; out="$(OS_SERVICES_ENV="$T/svc.env" run T b)"
grep -q "bot333:svctoken" "$CURL_URL" && ok "legacy services env still works as the last source" || no "services env ($out)"
reset; out="$(KC_TOKEN=111:bad KC_CHAT=42 API_OK=0 run T "b")"; rc=$?
[ $rc = 0 ] && grep -q "brain: text" "$BRAIN_LOG" && ok "Bot API not ok -> delivered through the brain" || no "no brain fallback ($out)"
reset; out="$(run T b)"; rc=$?
[ $rc = 0 ] && grep -q "brain: text" "$BRAIN_LOG" && ok "no local credentials at all -> brain fallback" || no "no-cred fallback ($out)"
reset; out="$(BRAIN_FAIL=1 run T b)"; rc=$?
[ $rc = 1 ] && printf '%s' "$out" | grep -q "NOT delivered" && ok "both paths failing exits 1 and says so" || no "silent failure ($rc $out)"
echo "notify: $p passed, $f failed"; [ "$f" = 0 ]
