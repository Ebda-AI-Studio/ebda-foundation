#!/usr/bin/env bash
# usage-sentinel (plan S2, incident 2026-10-26): a stale/absent reading is UNKNOWN + a page, never "low"; >= 80 % writes
# usage/fanout-stop; the Agent hook and agent-dispatch.sh refuse while it exists; a checkpoint pages once per week.
# Source status (2026-10-26): no TUI-independent reader is proven, so manual calibration + a fresh statusline snapshot.
set -uo pipefail
sedi() { local expr="$1"; shift; local f; for f in "$@"; do sed "$expr" "$f" > "$f.tmp" && mv "$f.tmp" "$f"; done; }   # portable in-place (BSD and GNU sed differ on -i)
HERE="$(cd "$(dirname "$0")" && pwd)"; OPS="$(cd "$HERE/.." && pwd)"
pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1 - got '$2' want '$3'"; fail=$((fail+1)); fi; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME/Desktop/projects" "$HOME/Library/Logs"
NOW=1792996000
cat > "$TMP/notify" <<EOS
#!/bin/bash
echo "\$1 | \$2" >> "$TMP/pages"
EOS
chmod +x "$TMP/notify"
export OS_ACTIONS_LOG="$TMP/actions.jsonl"
S() { # S <tag> [args]: one sentinel run with a per-tag state dir; sets RC, PAGES (cumulative per tag)
  local tag="$1"; shift
  env USAGE_STATE="$TMP/st-$tag" USAGE_SNAPSHOT="$TMP/snap-$tag.json" USAGE_NOTIFY="$TMP/notify" USAGE_NOW="${T_NOW:-$NOW}" ${S_ENV:-} \
    python3 "${PY:-$OPS/lib/usage_sentinel.py}" "$@" > "$TMP/out-$tag" 2>&1; RC=$?
  PAGES=$(wc -l < "$TMP/pages" | tr -d " ")
}
manual() { mkdir -p "$TMP/st-$1"; printf '{"pct":%s,"t":%s}' "$2" "${3:-$NOW}" > "$TMP/st-$1/manual.json"; }
snap() { printf '{"t":%s,"rl":{"five_hour":{"used_percentage":39,"resets_at":%s},"seven_day":{"used_percentage":%s,"resets_at":%s}}}' "$2" "$((NOW+3600))" "$3" "$((NOW+86400))" > "$TMP/snap-$1.json"; }
stopf() { echo "$TMP/st-$1/fanout-stop"; }

# 1. the incident replay: snapshot 115,616 s old, claims 20 %
: > "$TMP/pages"; snap a $((NOW-115616)) 20; S a --json
ok "1 stale snapshot (115,616 s) -> UNKNOWN exit 3" "$RC" "3"
ok "1 it pages exactly once, naming UNKNOWN" "$PAGES/$(grep -c 'UNKNOWN' "$TMP/pages")" "1/1"
ok "1 the reported pct is null, never 20" "$(python3 -c "import json;d=json.load(open('$TMP/st-a/status.json'));print(d['pct'],d['status'])")" "None unknown"
S a; ok "1b the next tick does not re-page inside the repeat window" "$PAGES" "1"
T_NOW=$((NOW+7*3600)) S a; ok "1c after 6 h it pages again (still UNKNOWN)" "$PAGES" "2"
# 2. missing everything
: > "$TMP/pages"; S b; ok "2 no files at all -> UNKNOWN + page" "$RC/$PAGES" "3/1"
# 3. fresh readings
: > "$TMP/pages"; snap c $((NOW-120)) 30; S c
ok "3 fresh snapshot 30 % -> ok, no page, no stop" "$RC/$PAGES/$([ -e "$(stopf c)" ] && echo stop || echo none)" "0/0/none"
manual d 22; S d; ok "3b manual 22 % -> ok" "$RC" "0"
manual e 22 $((NOW-7200)); S e; ok "3c manual reading 2 h old -> UNKNOWN (too old to trust)" "$RC" "3"
manual f 50 $((NOW-100)); snap f $((NOW-30)) 20; S f
ok "3d newest source wins (snapshot 20 % newer than manual 50 %)" "$(python3 -c "import json;print(json.load(open('$TMP/st-f/status.json'))['pct'])")" "20.0"
# 4. checkpoints
: > "$TMP/pages"; manual g 45; S g; ok "4 45 % crosses 40: one page, exit 1" "$RC/$PAGES" "1/1"
S g; ok "4b the same crossing a second time pages ONCE" "$PAGES" "1"
manual g 62; S g; ok "4c 62 % crosses 60: a new page" "$PAGES" "2"
# 5. the stop
: > "$TMP/pages"; manual h 81; S h
ok "5 81 % -> exit 1 and fanout-stop written" "$RC/$([ -e "$(stopf h)" ] && echo stop)" "1/stop"
ok "5b fanout-stop names the writer" "$(grep -c 'by=usage-sentinel' "$(stopf h)")" "1"
S h; ok "5c a second tick at 81 % pages once in total (80 checkpoint)" "$PAGES" "1"
manual h 91; S h; ok "5d 91 % crosses 90: pages again" "$PAGES" "2"
ok "5e the actions log has the stop write" "$(grep -c 'write fanout-stop' "$OS_ACTIONS_LOG")" "1"
manual h 30 $((NOW+10)); T_NOW=$((NOW+20)) S h
ok "5f reading back under 80 % removes OUR fanout-stop" "$([ -e "$(stopf h)" ] && echo stop || echo gone)" "gone"
mkdir -p "$TMP/st-i"; printf 'by=telegram /pause\n' > "$(stopf i)"; manual i 10; S i
ok "5g a fanout-stop written by someone else (/pause) is left alone" "$([ -e "$(stopf i)" ] && echo stop)" "stop"
# 6. garbage input is UNKNOWN, not a number
for bad in 150 -5 '"abc"' true null; do : > "$TMP/pages"; manual j "$bad"; rm -rf "$TMP/st-j/state.json"; S j; ok "6 manual pct=$bad -> UNKNOWN" "$RC" "3"; done
mkdir -p "$TMP/st-k"; echo '{not json' > "$TMP/st-k/manual.json"; S k; ok "6b corrupt manual.json -> UNKNOWN" "$RC" "3"
# 7. weekly window reset: a pre-reset reading is stale
mkdir -p "$TMP/st-l"; printf '{"pct":85,"t":%s,"resets_at":%s}' "$((NOW-60))" "$((NOW-30))" > "$TMP/st-l/manual.json"; S l
ok "7 reading from before the weekly reset -> UNKNOWN (no phantom STOP)" "$RC/$([ -e "$(stopf l)" ] && echo stop || echo none)" "3/none"
# 8. calibrate (Telegram /usage <n> path)
USAGE_STATE="$TMP/st-m" USAGE_NOW=$NOW python3 "$OPS/lib/usage_sentinel.py" calibrate 22 >/dev/null; S m
ok "8 calibrate 22 then check -> ok 22" "$RC/$(python3 -c "import json;print(json.load(open('$TMP/st-m/status.json'))['pct'])")" "0/22.0"
USAGE_STATE="$TMP/st-n" python3 "$OPS/lib/usage_sentinel.py" calibrate abc >/dev/null 2>&1; r1=$?
USAGE_STATE="$TMP/st-n" python3 "$OPS/lib/usage_sentinel.py" calibrate 150 >/dev/null 2>&1; r2=$?
ok "8b calibrate rejects non-numbers and >100" "$r1/$r2/$([ -e "$TMP/st-n/manual.json" ] && echo wrote || echo none)" "2/2/none"
# 9. the Agent hook
H="$OPS/hooks/deny-agent-on-usage-stop.sh"; export USAGE_STATE="$TMP/st-hook"; mkdir -p "$USAGE_STATE"
ap='{"tool_name":"Agent","tool_input":{"prompt":"x"}}'
printf '%s' "$ap" | bash "$H" >/dev/null 2>&1; ok "9 no fanout-stop: Agent allowed" "$?" "0"
printf 'by=usage-sentinel\npct=81\n' > "$USAGE_STATE/fanout-stop"
printf '%s' "$ap" | bash "$H" >/dev/null 2>"$TMP/hook.err"; ok "9b fanout-stop present: Agent DENIED (exit 2)" "$?" "2"
ok "9c the deny says how to lift it" "$(grep -c 'rm ' "$TMP/hook.err")" "1"
printf '%s' '{"tool_name":"Task","tool_input":{}}' | bash "$H" >/dev/null 2>&1; ok "9d Task denied too" "$?" "2"
printf '%s' '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | bash "$H" >/dev/null 2>&1; ok "9e other tools untouched while stopped" "$?" "0"
printf 'not json' | bash "$H" >/dev/null 2>&1; ok "9f malformed payload never bricks a session" "$?" "0"
unset USAGE_STATE
# 10. agent-dispatch refuses
mkdir -p "$TMP/bin" "$TMP/dispst/usage"; printf '#!/bin/bash\necho "$*" >> "%s/curl.calls"\n' "$TMP" > "$TMP/bin/curl"; printf '#!/bin/bash\necho run >> "%s/claude.calls"\nexit 0\n' "$TMP" > "$TMP/bin/claude"
chmod +x "$TMP/bin/curl" "$TMP/bin/claude"; printf 'by=usage-sentinel\n' > "$TMP/dispst/usage/fanout-stop"
D() { env PATH="$TMP/bin:$PATH" WHISKY_STATE_DIR="$TMP/dispst" TELEGRAM_BOT_TOKEN=x TELEGRAM_ALERT_CHAT_ID=1 TG_ENV=/nonexistent AGENT_TIMEOUT_SECONDS=20 ${D_ENV:-} bash "$OPS/agent-dispatch.sh" "do a thing in foundation" >/dev/null 2>&1; }
: > "$TMP/claude.calls"; : > "$TMP/curl.calls"; D
ok "10 dispatch with fanout-stop: claude NOT run, user told" "$(grep -c . "$TMP/claude.calls")/$(grep -c 'fan-out' "$TMP/curl.calls")" "0/1"
D_ENV="AGENT_DISPATCH_IGNORE_STOP=1" D
ok "10b explicit override proceeds to claude" "$(grep -c . "$TMP/claude.calls" | tr -d ' ' | sed 's/^[1-9].*/some/')" "some"
# 11. mutations
mkdir -p "$TMP/mut"; cp "$OPS/lib/usage_sentinel.py" "$TMP/mut/u.py"
sedi 's/MAX_AGE = int(os.environ.get("USAGE_MAX_AGE", "900"))/MAX_AGE = 10**9/' "$TMP/mut/u.py"
: > "$TMP/pages"; snap z $((NOW-115616)) 20; PY="$TMP/mut/u.py" S z
ok "11 MC with no staleness limit the 115,616 s snapshot reads as 20 % (case 1 is a real test)" "$RC" "0"
cp "$OPS/lib/usage_sentinel.py" "$TMP/mut/u2.py"; sedi 's/if pct >= STOP_PCT:/if pct > 1000:/' "$TMP/mut/u2.py"
manual y 81; PY="$TMP/mut/u2.py" S y
ok "11b MC without the stop rule 81 % writes nothing (case 5 is a real test)" "$([ -e "$(stopf y)" ] && echo stop || echo none)" "none"
echo; echo "passed=$pass failed=$fail"; [ "$fail" = 0 ]
