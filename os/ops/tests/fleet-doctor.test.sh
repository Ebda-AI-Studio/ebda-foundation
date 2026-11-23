#!/usr/bin/env bash
# fleet-doctor.sh: one verdict per subject, healthy and broken fixtures for each check. Fake gh/curl on PATH; throwaway HOME + state.
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
  *status=in_progress*) cat "$FK/inprogress.json" 2>/dev/null || exit 1 ;;
  *status=queued*) cat "$FK/queued.json" 2>/dev/null || exit 1 ;;
  *actions/variables/EBDA_RUNS_ON*) [ -f "$FK/var" ] || exit 1; cat "$FK/var" ;;
  *actions/runners*) [ -f "$FK/runners.json" ] || exit 1; cat "$FK/runners.json" ;;
  *"/rulesets"*) [ -f "$FK/rulesets" ] || exit 1; cat "$FK/rulesets" ;;
  "pr list"*) [ -f "$FK/prs.json" ] || exit 1; cat "$FK/prs.json" ;;
  *) exit 1 ;;
esac
FAKE
cat > "$BIN/curl" <<'FAKE'
#!/usr/bin/env bash
[ -f "${FAKE_DIR:?}/date" ] || exit 1
printf 'HTTP/2 200\r\nDate: %s\r\n\r\n' "$(cat "$FAKE_DIR/date")"
FAKE
chmod +x "$BIN/gh" "$BIN/curl"
printf '#!/bin/sh\necho "$*" >> "%s/notify.log"\n' "$FK" > "$T/notify.sh"; chmod +x "$T/notify.sh"
runs() { printf '{"total_count":%s,"workflow_runs":[]}' "$2" > "$FK/$1.json"; }
healthy() {
  runs inprogress 2; runs queued 0; echo '["ubuntu-24.04"]' > "$FK/var"; echo '{"runners":[]}' > "$FK/runners.json"
  echo 'main-protection' > "$FK/rulesets"; echo '[]' > "$FK/prs.json"
  date -u '+%a, %d %b %Y %H:%M:%S GMT' > "$FK/date"
}
fd() { PATH="$BIN:$PATH" FAKE_DIR="$FK" HOME="$T/home" OS_STATE_DIR="$T/state" DOCTOR_INSTALLED="$T/inst" FLEET_DOCTOR_NOTIFY="$T/notify.sh" bash "$OPS/fleet-doctor.sh" "$@"; }
verdict() { printf '%s\n' "$1" | awk -F'\t' -v s="$2" '$1==s {print $2}'; }

healthy
mkdir -p "$T/co"; ( cd "$T/co" && git init -q . )
out="$(fd --repo o/r --dir "$T/co")"; rc=$?
ok "healthy hosted repo: only the not-installed ops-drift is UNKNOWN (exit 2)" "$rc" "2"
ok "ci-target OK (hosted var)"   "$(verdict "$out" 'o/r ci-target')" "OK"
ok "queue OK"                    "$(verdict "$out" 'o/r queue')" "OK"
ok "main-protect OK"             "$(verdict "$out" 'o/r main-protect')" "OK"
ok "conflicts OK"                "$(verdict "$out" 'o/r conflicts')" "OK"
ok "git-config OK"               "$(verdict "$out" "git-config $T/co")" "OK"
ok "clock OK"                    "$(verdict "$out" 'clock')" "OK"
ok "ops-drift: no separate install is UNKNOWN, never OK" "$(verdict "$out" 'ops-drift')" "UNKNOWN"
ok "healthy run: no notify" "$(test -f "$FK/notify.log" && echo sent || echo none)" "none"

# ops-drift against a real installed copy
mkdir -p "$T/inst/hooks"
for f in "$OPS"/*.sh "$OPS"/hooks/*.sh; do cp "$f" "$T/inst/${f#"$OPS"/}"; done
out="$(fd --repo o/r)"; ok "installed == merged: OK" "$(verdict "$out" 'ops-drift')" "OK"
echo '# drift' >> "$T/inst/capacity.sh"; rm "$T/inst/hooks/block-stash-pop.sh"
out="$(fd --repo o/r)"
ok "installed differs + missing: FAIL" "$(verdict "$out" 'ops-drift')" "FAIL"
ok "drift evidence names both files" "$(printf '%s\n' "$out" | grep 'ops-drift' | grep -c 'capacity.sh(differs).*block-stash-pop.sh(missing)')" "1"
for f in "$OPS"/*.sh "$OPS"/hooks/*.sh; do cp "$f" "$T/inst/${f#"$OPS"/}"; done

# broken fixtures, one per check
rm "$FK/var"; echo '{"runners":[{"name":"m","status":"offline","busy":false,"labels":[]}]}' > "$FK/runners.json"
out="$(fd --repo o/r --no-notify)"; rc=$?
ok "var unset + 0 online runners: ci-target FAIL, exit 1" "$(verdict "$out" 'o/r ci-target'):$rc" "FAIL:1"
echo '{"runners":[{"name":"m","status":"online","busy":false,"labels":[]}]}' > "$FK/runners.json"
ok "var unset but a Mac runner online: OK" "$(verdict "$(fd --repo o/r --no-notify)" 'o/r ci-target')" "OK"
echo '["ubuntu-24.04"]' > "$FK/var"
runs inprogress 20; ok "queue saturated: FAIL" "$(verdict "$(fd --repo o/r --no-notify)" 'o/r queue')" "FAIL"
runs inprogress 2; rm "$FK/queued.json"; ok "queue unreadable: UNKNOWN" "$(verdict "$(fd --repo o/r --no-notify)" 'o/r queue')" "UNKNOWN"; runs queued 0
echo 'something-else' > "$FK/rulesets"; ok "no main-protection ruleset: FAIL" "$(verdict "$(fd --repo o/r --no-notify)" 'o/r main-protect')" "FAIL"
rm "$FK/rulesets"; ok "rulesets unreadable: UNKNOWN" "$(verdict "$(fd --repo o/r --no-notify)" 'o/r main-protect')" "UNKNOWN"; echo main-protection > "$FK/rulesets"
echo '[{"number":5,"mergeable":"CONFLICTING","labels":[]},{"number":6,"mergeable":"CONFLICTING","labels":[{"name":"rebase-needed"}]}]' > "$FK/prs.json"
out="$(fd --repo o/r --no-notify)"
ok "conflict without rebase-needed: FAIL naming #5 only" "$(verdict "$out" 'o/r conflicts'):$(printf '%s\n' "$out" | grep 'o/r conflicts' | grep -c '#5$')" "FAIL:1"
echo '[]' > "$FK/prs.json"
( cd "$T/co" && git config core.bare true ); out="$(fd --repo o/r --dir "$T/co" --no-notify)"
ok "core.bare=true on a checkout: FAIL" "$(verdict "$out" "git-config $T/co")" "FAIL"
( cd "$T/co" && git config core.bare false )
ok "not a git dir: UNKNOWN" "$(verdict "$(fd --repo o/r --dir "$T" --no-notify)" "git-config $T")" "UNKNOWN"
date -u -d '10 minutes ago' '+%a, %d %b %Y %H:%M:%S GMT' > "$FK/date" 2>/dev/null || date -u -v-10M '+%a, %d %b %Y %H:%M:%S GMT' > "$FK/date"
ok "clock skew 10 min: FAIL" "$(verdict "$(fd --repo o/r --no-notify)" clock)" "FAIL"
rm "$FK/date"; ok "no Date header: UNKNOWN" "$(verdict "$(fd --repo o/r --no-notify)" clock)" "UNKNOWN"
healthy

# notify once per distinct FAIL set; exit codes
rm -f "$FK/notify.log"; runs inprogress 20
fd --repo o/r >/dev/null; rc1=$?; fd --repo o/r >/dev/null
ok "FAIL announced once for the same set" "$(wc -l < "$FK/notify.log" | tr -d ' ')" "1"
ok "FAIL exit 1" "$rc1" "1"
runs inprogress 2; fd --repo o/r >/dev/null; runs inprogress 20; fd --repo o/r >/dev/null
ok "recovery then a new failure announces again" "$(wc -l < "$FK/notify.log" | tr -d ' ')" "2"
ok "last.tsv written" "$(test -s "$T/state/fleet-doctor/last.tsv" && echo yes)" "yes"
fd --bogus >/dev/null 2>&1; ok "unknown flag exit 2" "$?" "2"
ok "--help exit 0" "$(bash "$OPS/fleet-doctor.sh" --help >/dev/null 2>&1; echo $?)" "0"
echo "---"; echo "fleet-doctor: $pass passed, $fail failed"; [ "$fail" = 0 ]
