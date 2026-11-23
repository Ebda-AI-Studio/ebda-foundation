#!/usr/bin/env bash
# sched-fail-watch: a failed scheduled job (launchd or GitHub schedule workflow) opens ONE fixer issue, deduped, cleared on recovery.
# Fakes: launchctl + gh + notify on PATH/env. Run: bash os/ops/tests/sched-fail-watch.test.sh
set -uo pipefail
OPS="$(cd "$(dirname "$0")/.." && pwd)"
p=0; f=0; ok() { echo "PASS: $1"; p=$((p+1)); }; no() { echo "FAIL: $1"; f=$((f+1)); }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/la" "$T/launchctl"
export HOME="$T/home"; mkdir -p "$HOME"
export OS_LOCK_DIR="$T/locks" SFW_STATE="$T/st" JF_FAILURE_STATE="$T/jf" WHISKY_OS_STATE="$T/ws"
export OS_REPO_SLUG="acme/os" OS_ORG="acme" OS_LAUNCHD_PREFIX="com.ebda.os"
export SFW_LAUNCHD_DIR="$T/la" SFW_NOTIFY="$T/notify" SFW_REPOS="acme/app" SFW_NOW="$(date -u +%s)"
export JF_FAILURE_GH="$T/bin/gh" SFW_GH="$T/bin/gh" FAKE="$T/launchctl" GH_LOG="$T/gh.log" NOTE_LOG="$T/notify.log" RUNS="$T/runs.json"
# fake launchctl: `launchctl print gui/501/<label>` prints $FAKE/<label>
cat > "$T/bin/launchctl" <<'S'
#!/bin/bash
[ "$1" = print ] && cat "$FAKE/${2##*/}" 2>/dev/null || exit 113
S
# fake gh: logs calls, serves $RUNS for `run list`, numbers issues
cat > "$T/bin/gh" <<'S'
#!/bin/bash
echo "$*" >> "$GH_LOG"
case "$1 $2" in
  "run list") cat "$RUNS" ;;
  "issue create") echo "https://github.com/acme/os/issues/$(grep -c 'issue create' "$GH_LOG")" ;;
  *) exit 0 ;;
esac
S
printf '#!/bin/bash\necho "$*" >> "$NOTE_LOG"\n' > "$T/notify"
chmod +x "$T/bin/"* "$T/notify"
export PATH="$T/bin:$PATH"
issues() { grep -c 'issue create' "$GH_LOG" 2>/dev/null || true; }
notes()  { grep -c . "$NOTE_LOG" 2>/dev/null || true; }
run() { bash "$OPS/sched-fail-watch.sh" >"$T/out" 2>&1; }
touchlog() { sleep 1; echo "$2" >> "$T/$1.log"; }
mkplist() { cat > "$T/la/com.ebda.os.$1.plist" <<P
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>Label</key><string>com.ebda.os.$1</string><key>StandardErrorPath</key><string>$T/$1.log</string></dict></plist>
P
}
: > "$GH_LOG"; : > "$NOTE_LOG"; echo '[]' > "$RUNS"

# ---------- (a) launchd ----------
mkplist backup; echo "boom: backup failed" > "$T/backup.log"
printf '\tlast exit code = 1\n' > "$FAKE/com.ebda.os.backup"
run; [ "$(issues)" = 0 ] && ok "1st failing run: no fixer yet (flaky guard)" || no "filed on first failure ($(issues))"
run; [ "$(issues)" = 0 ] && ok "same run seen again (log unchanged): still no fixer" || no "an unchanged signature counted as a 2nd run"
touchlog backup "boom again"
run; [ "$(issues)" = 1 ] && [ "$(notes)" = 1 ] && ok "2nd distinct failing run: ONE fixer issue + ONE telegram" || no "expected 1 issue/1 note, got $(issues)/$(notes)"
grep -q 'review-finding' "$GH_LOG" && grep -q 'job-failure: com.ebda.os.backup' "$GH_LOG" && ok "issue goes to the review-finding queue" || no "wrong issue shape"
run; run; [ "$(issues)" = 1 ] && [ "$(notes)" = 1 ] && ok "next ticks: deduped (still 1 issue, 1 note)" || no "not deduped ($(issues)/$(notes))"
printf '\tlast exit code = 0\n' > "$FAKE/com.ebda.os.backup"; run
if [ ! -e "$SFW_STATE/launchd/com.ebda.os.backup.streak" ] && ! ls "$JF_FAILURE_STATE"/com.ebda.os.backup.* >/dev/null 2>&1; then ok "recovery clears streak + stamp"; else no "recovery left state behind"; fi
printf '\tlast exit code = 2\n' > "$FAKE/com.ebda.os.backup"; touchlog backup x; run; touchlog backup y; run
[ "$(issues)" = 2 ] && ok "after recovery a NEW failure opens a fresh fixer" || no "post-recovery failure not filed ($(issues))"

# ---------- (b) scheduled workflows ----------
: > "$GH_LOG"; : > "$NOTE_LOG"; rm -f "$T/la/"*.plist
ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "[{\"databaseId\":77,\"workflowName\":\"nightly\",\"conclusion\":\"failure\",\"status\":\"completed\",\"createdAt\":\"$ts\",\"url\":\"https://x/77\"},
      {\"databaseId\":70,\"workflowName\":\"nightly\",\"conclusion\":\"success\",\"status\":\"completed\",\"createdAt\":\"2020-01-01T00:00:00Z\",\"url\":\"https://x/70\"}]" > "$RUNS"
run; [ "$(issues)" = 1 ] && [ "$(notes)" = 1 ] && ok "red scheduled workflow: ONE fixer + ONE telegram" || no "workflow not filed ($(issues)/$(notes))"
run; run; [ "$(issues)" = 1 ] && [ "$(notes)" = 1 ] && ok "deduped on the next ticks" || no "workflow not deduped ($(issues)/$(notes))"
rm -f "$JF_FAILURE_STATE"/wf-*; run; [ "$(issues)" = 1 ] && ok "same failing run id on a new day: no duplicate issue" || no "re-filed the same run"
echo "[{\"databaseId\":78,\"workflowName\":\"nightly\",\"conclusion\":\"cancelled\",\"status\":\"completed\",\"createdAt\":\"$ts\",\"url\":\"u\"},{\"databaseId\":77,\"workflowName\":\"nightly\",\"conclusion\":\"failure\",\"status\":\"completed\",\"createdAt\":\"$ts\",\"url\":\"u\"}]" > "$RUNS"
run; [ "$(issues)" = 1 ] && ok "a cancelled run changes nothing" || no "cancelled run caused a filing"
echo "[{\"databaseId\":79,\"workflowName\":\"nightly\",\"conclusion\":\"success\",\"status\":\"completed\",\"createdAt\":\"$ts\",\"url\":\"u\"}]" > "$RUNS"; run
echo "[{\"databaseId\":80,\"workflowName\":\"nightly\",\"conclusion\":\"failure\",\"status\":\"completed\",\"createdAt\":\"$ts\",\"url\":\"u\"}]" > "$RUNS"; run
[ "$(issues)" = 2 ] && ok "green run clears; the next red run files again" || no "recovery cycle broken ($(issues))"
echo "[{\"databaseId\":5,\"workflowName\":\"old\",\"conclusion\":\"failure\",\"status\":\"completed\",\"createdAt\":\"2020-01-01T00:00:00Z\",\"url\":\"u\"}]" > "$RUNS"; run
[ "$(issues)" = 2 ] && ok "a year-old red run is history, not news" || no "stale failure filed"

# ---------- guards ----------
: > "$GH_LOG"; : > "$NOTE_LOG"; echo '[]' > "$RUNS"
bash "$OPS/sched-fail-watch.sh" >/dev/null 2>&1; [ $? = 0 ] && ok "quiet tick exits 0" || no "quiet tick nonzero"
[ "$(issues)" = 0 ] && [ "$(notes)" = 0 ] && ok "nothing failed: no issue, no telegram" || no "noise on a quiet tick"
grep -qE 'claude( |-p)' "$OPS/sched-fail-watch.sh" && no "watcher calls a model" || ok "no model call in the watcher (zero tokens)"
grep -qE '"\$\{[A-Za-z_]+\[@\]\}"' "$OPS/sched-fail-watch.sh" && no "bare array expansion (bash 3.2 empty-array hazard)" || ok "no bare \${arr[@]} expansion (bash 3.2 safe)"
echo "sched-fail-watch: $p passed, $f failed"; [ "$f" = 0 ]
