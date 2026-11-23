#!/usr/bin/env bash
# capacity.sh: hosted-queue capacity from the GitHub API. Fake `gh` serves fixtures; UNKNOWN fails closed; nothing is deleted.
set -uo pipefail
OPS="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok() { if [ "$2" = "$3" ]; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1 - got '$2' want '$3'"; fail=$((fail+1)); fi; }
BIN="$T/bin"; FK="$T/fk"; mkdir -p "$BIN" "$FK" "$T/home"
cat > "$BIN/gh" <<'FAKE'
#!/usr/bin/env bash
FK="${FAKE_DIR:?}"
case "$*" in
  *status=in_progress*) f="$FK/inprogress.json" ;;
  *status=queued*) f="$FK/queued.json" ;;
  *actions/variables/EBDA_RUNS_ON*) [ -f "$FK/var" ] || exit 1; cat "$FK/var"; exit 0 ;;
  *actions/runners*) f="$FK/runners.json" ;;
  *) exit 1 ;;
esac
[ -f "$f" ] || exit 1
cat "$f"
FAKE
chmod +x "$BIN/gh"
runs() { # file count [created_at...]
  python3 - "$@" <<'PY'
import sys, json
f, n = sys.argv[1], int(sys.argv[2])
json.dump({"total_count": n, "workflow_runs": [{"created_at": t} for t in sys.argv[3:]]}, open(f, "w"))
PY
}
ago() { python3 -c 'import sys,datetime; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(minutes=int(sys.argv[1]))).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$1"; }
run() { PATH="$BIN:$PATH" FAKE_DIR="$FK" HOME="$T/home" OS_STATE_DIR="$T/state" bash "$OPS/capacity.sh" "$@"; }
echo '{"runners":[]}' > "$FK/runners.json"; echo '["ubuntu-24.04"]' > "$FK/var"

runs "$FK/inprogress.json" 3; runs "$FK/queued.json" 0
out="$(run --repo o/r)"; rc=$?
ok "idle: exit 0" "$rc" "0"
ok "idle: OK + hosted" "$(printf '%s' "$out" | head -1 | cut -f2,6)" "$(printf 'OK\tci=hosted')"
runs "$FK/inprogress.json" 16; out="$(run --repo o/r)"; rc=$?
ok "16/20 in progress: BUSY, still exit 0" "$(printf '%s' "$out" | head -1 | cut -f2):$rc" "BUSY:0"
runs "$FK/inprogress.json" 20; out="$(run --repo o/r)"; rc=$?
ok "20/20: SATURATED exit 1" "$(printf '%s' "$out" | head -1 | cut -f2):$rc" "SATURATED:1"
runs "$FK/inprogress.json" 2; runs "$FK/queued.json" 1 "$(ago 45)"; out="$(run --repo o/r)"; rc=$?
ok "queued 45 min: STARVED exit 1" "$(printf '%s' "$out" | head -1 | cut -f2):$rc" "STARVED:1"
runs "$FK/queued.json" 1 "$(ago 3)"; out="$(run --repo o/r)"; rc=$?
ok "queued 3 min: BUSY" "$(printf '%s' "$out" | head -1 | cut -f2):$rc" "BUSY:0"
ok "--run-limit 2 turns 2 in progress SATURATED" "$(run --repo o/r --run-limit 2 | head -1 | cut -f2)" "SATURATED"
rm "$FK/queued.json"; out="$(run --repo o/r)"; rc=$?
ok "unreadable read: UNKNOWN exit 2 (fail closed, never free)" "$(printf '%s' "$out" | head -1 | cut -f2):$rc" "UNKNOWN:2"
echo 'not json' > "$FK/queued.json"; ok "garbage JSON: UNKNOWN" "$(run --repo o/r | head -1 | cut -f2)" "UNKNOWN"
runs "$FK/queued.json" 0; rm "$FK/var"
ok "var unset reported" "$(run --repo o/r | head -1 | cut -f6)" "ci=unset"
ok "status file written" "$(test -s "$T/state/capacity/status.tsv" && echo yes)" "yes"
ok "host-disk row present" "$(run --repo o/r | grep -c '^host-disk')" "1"
# df failure -> UNKNOWN, no fake free space
printf '#!/bin/sh\nexit 1\n' > "$BIN/df"; chmod +x "$BIN/df"
out="$(run --repo o/r)"; rc=$?
ok "df failure: host-disk UNKNOWN, exit 2" "$(printf '%s' "$out" | grep '^host-disk' | cut -f2):$rc" "UNKNOWN:2"
rm "$BIN/df"
run --bogus >/dev/null 2>&1; ok "unknown flag exit 2" "$?" "2"
ok "--help exit 0" "$(bash "$OPS/capacity.sh" --help >/dev/null 2>&1; echo $?)" "0"
echo "---"; echo "capacity: $pass passed, $fail failed"; [ "$fail" = 0 ]
