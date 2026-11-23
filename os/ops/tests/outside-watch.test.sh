#!/usr/bin/env bash
# outside-watch.sh with a stub curl + notify: 2-failure rule, one alert per outage, reminder window, recovery, offline control skip, failed delivery retries.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
W="$ROOT/os/ops/outside-watch.sh"
p=0; f=0; ok() { echo "PASS: $1"; p=$((p+1)); }; no() { echo "FAIL: $1"; f=$((f+1)); }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"; export OS_STATE_DIR="$T/state" EBDA_OS_LOCAL_ENV="$T/none.env"
cat > "$T/cfg.json" <<J
{"probes":[{"name":"api","url":"https://api.test/health","expect":200,"contains":"\"status\":\\\\s*\"ok\""},{"name":"web","url":"https://web.test/","expect":200}]}
J
# stub curl: CTRL_FAIL=1 fails the control; API_MODE = ok|down|badbody; writes body to the -o file, prints the code for -w
cat > "$T/curl" <<'S'
#!/bin/bash
out=""; url=""; while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift ;; http*) url="$1" ;; esac; shift; done
case "$url" in
  *captive*) [ -n "${CTRL_FAIL:-}" ] && exit 6; exit 0 ;;
  *api.test*) case "${API_MODE:-ok}" in down) exit 7 ;; badbody) echo '{"status":"degraded"}' > "$out"; printf 200 ;; *) echo '{"status": "ok"}' > "$out"; printf 200 ;; esac ;;
  *) echo hi > "$out"; printf 200 ;;
esac
S
cat > "$T/notify" <<'S'
#!/bin/bash
[ -n "${NOTIFY_FAIL:-}" ] && exit 1
echo "$*" >> "$NOTIFY_LOG"
S
chmod +x "$T/curl" "$T/notify"; export NOTIFY_LOG="$T/notify.log" OUTSIDE_WATCH_CURL="$T/curl" OUTSIDE_WATCH_NOTIFY="$T/notify"
run() { bash "$W" --config "$T/cfg.json" 2>&1; }
n() { [ -f "$NOTIFY_LOG" ] && wc -l < "$NOTIFY_LOG" | tr -d ' ' || echo 0; }
reset() { rm -rf "$OS_STATE_DIR" "$NOTIFY_LOG"; unset API_MODE CTRL_FAIL NOTIFY_FAIL OUTSIDE_WATCH_NOW; }

reset; run >/dev/null; [ "$(n)" = 0 ] && ok "all healthy: no alert" || no "alerted while healthy"
reset; API_MODE=down run >/dev/null; [ "$(n)" = 0 ] && ok "first failure does not alert" || no "alerted on one blip"
API_MODE=down run >/dev/null; [ "$(n)" = 1 ] && grep -q "api (https://api.test/health)" "$NOTIFY_LOG" && ok "second consecutive failure alerts once, naming the probe" || no "no alert on 2nd failure"
API_MODE=down run >/dev/null; [ "$(n)" = 1 ] && ok "still down inside the reminder window: no repeat" || no "repeated alert"
OUTSIDE_WATCH_NOW=$(( $(date +%s) + 7*3600 )) API_MODE=down run >/dev/null; [ "$(n)" = 2 ] && ok "reminder after the window" || no "no reminder"
run >/dev/null; [ "$(n)" = 3 ] && grep -q "RECOVERED" < <(tail -1 "$NOTIFY_LOG") && ok "recovery message once" || no "no recovery"
run >/dev/null; [ "$(n)" = 3 ] && ok "no second recovery" || no "recovery repeated"
reset; API_MODE=badbody run >/dev/null; API_MODE=badbody run >/dev/null; grep -q "body does not match" "$NOTIFY_LOG" && ok "wrong body counts as down" || no "bad body not detected"
reset; CTRL_FAIL=1 API_MODE=down run >/dev/null; CTRL_FAIL=1 API_MODE=down run >/dev/null; [ "$(n)" = 0 ] && ok "offline Mac (control fails): run skipped, no alert" || no "alerted while offline"
reset; NOTIFY_FAIL=1 API_MODE=down run >/dev/null; NOTIFY_FAIL=1 API_MODE=down run >/dev/null; API_MODE=down run >/dev/null; [ "$(n)" = 1 ] && ok "failed delivery is retried on the next tick" || no "failed delivery not retried"
echo "outside-watch: $p passed, $f failed"; [ "$f" = 0 ]
