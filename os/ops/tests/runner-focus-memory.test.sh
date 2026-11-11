#!/usr/bin/env bash
# runner-focus.sh must not START runners into a memory-starved guest, and must not start them as a wave.
set -uo pipefail
export OS_UMBRA_VMS=umbra-ci6   # fixture guest name; the shipped default lives only in os.env
cd "$(dirname "$0")/.."; OPS="$(pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1 — got '$2' want '$3'"; fail=$((fail+1)); fi; }
export HOME="$TMP/home"; mkdir -p "$HOME/.umbra"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/umbra" <<STUB
#!/usr/bin/env bash
# umbra exec <guest> -- "<cmd>"
cmd="\${4:-}"
case "\$cmd" in
  *MemAvailable*) [ "\${FAKE_AVAIL:-3000}" = none ] || echo "\${FAKE_AVAIL:-3000}" ;;
  *list-unit-files*) printf 'actions.runner.Org-alpha.umbra-ci6-alpha-1.service\nactions.runner.Org-alpha.umbra-ci6-alpha-2.service\nactions.runner.Org-beta.umbra-ci6-beta-1.service\n' ;;
  *"enable --now"*) echo "\$cmd" >> "$TMP/starts" ;;
esac
exit 0
STUB
printf '#!/bin/sh\necho "$1" >> "%s/sleeps"\n' "$TMP" > "$TMP/bin/sleep"
chmod +x "$TMP/bin/umbra" "$TMP/bin/sleep"
export PATH="$TMP/bin:$PATH" RUNNER_FOCUS_FILE="$TMP/focus.json" RUNNER_FOCUS_STAGGER_SEC=4
run() { rm -f "$TMP/starts" "$TMP/sleeps"; bash "$OPS/runner-focus.sh" "$@" > "$TMP/out" 2>&1; RC=$?; STARTS=$(grep -c . "$TMP/starts" 2>/dev/null || echo 0); }

FAKE_AVAIL=3000 run on alpha
ok "enough memory: both alpha runners start" "$STARTS" "2"
ok "starts are staggered (sleep 4 after each)" "$(grep -c '^4$' "$TMP/sleeps")" "2"
FAKE_AVAIL=200 run on alpha
ok "guest memory 200 MB < 500: NO runner is started" "$STARTS" "0"
ok "it says DEFER and exits non-zero" "$(grep -c DEFER "$TMP/out"):$([ "$RC" != 0 ] && echo nz)" "2:nz"
FAKE_AVAIL=200 RUNNER_FOCUS_MIN_AVAIL_MB=0 run on beta
ok "RUNNER_FOCUS_MIN_AVAIL_MB=0 overrides the guard" "$STARTS" "1"
FAKE_AVAIL=none run on beta
ok "unreadable memory is NOT ok: refuses to start blind" "$STARTS" "0"
echo '["alpha"]' > "$TMP/focus.json"
FAKE_AVAIL=200 run all
ok "'all' on a starved guest starts nothing and KEEPS the focus file" "$STARTS:$([ -f "$TMP/focus.json" ] && echo kept)" "0:kept"
FAKE_AVAIL=3000 run all
ok "'all' with enough memory starts all three and drops the focus file" "$STARTS:$([ -f "$TMP/focus.json" ] && echo kept || echo gone)" "3:gone"

echo "$pass passed, $fail failed"; [ "$fail" = 0 ]
