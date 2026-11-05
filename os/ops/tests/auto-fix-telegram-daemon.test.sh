#!/usr/bin/env bash
# auto-fix-telegram-daemon: every command arm must be REACHABLE.
#
# Bug (shellcheck SC2221/SC2222): the `/*)` unknown-command arm sat above `/kill` and
# `/resume`, so bash matched it first — the autonomy kill switch answered "Unknown
# command" and never froze anything. This drives the real daemon with a stub curl (no
# network), one poll iteration per message.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DAEMON="${DAEMON:-$HERE/../auto-fix-telegram-daemon.sh}"
pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1 — got '$2' want '$3'"; fail=$((fail+1)); fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME/.claude" "$TMP/bin"
export WHISKY_STATE_DIR="$TMP/state" TG_ENV="$TMP/none.env" TG_ONESHOT=1
export TELEGRAM_BOT_TOKEN=stub TELEGRAM_ALERT_CHAT_ID=42
export SENT="$TMP/sent" TEXT_FILE="$TMP/text"

# stub curl: getUpdates -> one canned update; sendMessage -> record the text; never the network
cat > "$TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *getUpdates*)
    python3 -c 'import json,os;print(json.dumps({"ok":True,"result":[{"update_id":7,"message":{"text":open(os.environ["TEXT_FILE"]).read(),"chat":{"id":42},"from":{"username":"t"}}}]}))' ;;
  *sendMessage*)
    while [ $# -gt 0 ]; do case "$1" in text=*) printf '%s\n' "${1#text=}" >> "$SENT" ;; esac
      shift; done ;;
esac
exit 0
STUB
chmod +x "$TMP/bin/curl"
export PATH="$TMP/bin:$PATH"

send() { printf '%s' "$1" > "$TEXT_FILE"; : > "$SENT"; bash "$DAEMON" >/dev/null 2>&1; }

send "/kill"
ok "/kill freezes autonomy (flag file exists)" "$([ -f "$WHISKY_STATE_DIR/AUTONOMY_OFF" ] && echo yes || echo no)" "yes"
ok "/kill replies FROZEN, not 'Unknown command'" "$(grep -c 'FROZEN' "$SENT"):$(grep -c 'Unknown command' "$SENT")" "1:0"

send "/resume"
ok "/resume clears the flag" "$([ -f "$WHISKY_STATE_DIR/AUTONOMY_OFF" ] && echo yes || echo no)" "no"
ok "/resume replies RESUMED, not 'Unknown command'" "$(grep -c 'RESUMED' "$SENT"):$(grep -c 'Unknown command' "$SENT")" "1:0"

send "/bogus"
ok "unknown slash command still hits the catch-all" "$(grep -c 'Unknown command' "$SENT")" "1"

send "/kill@mybot"
ok "/kill@bot suffix is stripped and still handled" "$([ -f "$WHISKY_STATE_DIR/AUTONOMY_OFF" ] && echo yes || echo no)" "yes"

echo; echo "auto-fix-telegram-daemon: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
