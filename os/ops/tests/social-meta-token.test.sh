#!/usr/bin/env bash
# social-meta-token.sh offline: curl / security / pbpaste / pbcopy / npx are PATH fakes (Graph answers use the documented shapes), so the
# real Keychain, Meta and Cloudflare are never touched. Checks: page tokens reach the secret, nothing secret is printed, bad input refused,
# an expiring token is refused.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
p=0; f=0
ok() { echo "PASS: $1"; p=$((p+1)); }
no() { echo "FAIL: $1"; f=$((f+1)); }
mkdir -p "$T/bin" "$T/kc"
APPSEC=0123456789abcdef0123456789abcdef
USERTOK="EAAG$(printf 'u%.0s' $(seq 1 60))"
cat >"$T/bin/pbpaste" <<EOF
#!/usr/bin/env bash
cat "$T/clip"
EOF
cat >"$T/bin/pbcopy" <<EOF
#!/usr/bin/env bash
cat >"$T/clip"
EOF
cat >"$T/bin/security" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "-i" ]; then line="\$(cat)"; s="\$(sed -E 's/.* -s ([^ ]+) -w .*/\1/' <<<"\$line")"; v="\$(sed -E 's/.* -w "(.*)"$/\1/' <<<"\$line")"; printf '%s' "\$v" >"$T/kc/\$s"; exit 0; fi
if [ "\$1" = "find-generic-password" ]; then [ -f "$T/kc/\$3" ] && cat "$T/kc/\$3" && exit 0; exit 44; fi
exit 1
EOF
cat >"$T/bin/curl" <<EOF
#!/usr/bin/env bash
cfg="\$(cat)"; echo "\$cfg" >>"$T/curl.log"
case "\$cfg" in
  *oauth/access_token*) echo '{"access_token":"EAAGlonglived0000000000000000000000000000000","token_type":"bearer","expires_in":5183944}' ;;
  *me/accounts*) echo '{"data":[{"id":"111","name":"Ebda AI Studio","access_token":"EAAGpageEBDA000000000000000000000000000","tasks":["ADVERTISE","ANALYZE","CREATE_CONTENT","MESSAGING","MODERATE","MANAGE"]},{"id":"222","name":"Whisky 11","access_token":"EAAGpageW11000000000000000000000000000000","tasks":["CREATE_CONTENT","MANAGE"]}],"paging":{}}' ;;
  *debug_token*input_token=EAAGpageW11*) echo "{\"data\":{\"app_id\":\"1733132125094316\",\"type\":\"PAGE\",\"is_valid\":true,\"expires_at\":\${W11_EXP:-0},\"scopes\":[\"pages_show_list\",\"pages_read_engagement\",\"pages_manage_posts\"]}}" ;;
  *debug_token*) echo '{"data":{"app_id":"1733132125094316","type":"PAGE","is_valid":true,"expires_at":0,"scopes":["pages_show_list","pages_read_engagement","pages_manage_posts","pages_read_user_content"]}}' ;;
  *) echo '{"error":{"message":"unrouted","code":1}}' ;;
esac
EOF
cat >"$T/bin/npx" <<EOF
#!/usr/bin/env bash
echo "\$*" >"$T/npx.args"; cat >"$T/npx.stdin"
EOF
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH" HOME="$T"

printf 'not-a-secret' >"$T/clip"
printf 'not-a-secret' | bash "$HERE/social-meta-token.sh" --save-app-secret --stdin >"$T/out" 2>&1 && no "a non-hex App Secret was accepted" || ok "a non-hex App Secret is refused"
printf '%s' "$APPSEC" | bash "$HERE/social-meta-token.sh" --save-app-secret --stdin >"$T/out" 2>&1
[ "$(cat "$T/kc/ebda-os-meta-app-secret" 2>/dev/null)" = "$APPSEC" ] && ok "--save-app-secret stores the App Secret in Keychain" || no "App Secret not stored ($(cat "$T/out"))"
grep -q "$APPSEC" "$T/out" && no "App Secret printed" || ok "App Secret is not printed"

printf 'hello' | bash "$HERE/social-meta-token.sh" --stdin >"$T/out" 2>&1 && no "a non-token was accepted" || ok "input that is not a user token is refused"

printf '%s' "$USERTOK" | bash "$HERE/social-meta-token.sh" --stdin >"$T/out" 2>&1; rc=$?
[ "$rc" = 0 ] && ok "the exchange succeeds (exit 0)" || no "exit $rc: $(cat "$T/out")"
sec="$(cat "$T/npx.stdin" 2>/dev/null)"
python3 -I -c 'import json,sys; d=json.loads(sys.argv[1]); assert d=={"ebda":{"pageId":"111","pageToken":"EAAGpageEBDA000000000000000000000000000"},"whisky11":{"pageId":"222","pageToken":"EAAGpageW11000000000000000000000000000000"}}' "$sec" 2>/dev/null \
  && ok "SOCIAL_FACEBOOK gets both Page tokens, keyed by brand" || no "secret JSON wrong: $sec"
grep -q -- "secret put SOCIAL_FACEBOOK --name ebda-os-brain" "$T/npx.args" && ok "wrangler secret put targets ebda-os-brain" || no "npx args: $(cat "$T/npx.args" 2>/dev/null)"
[ "$(base64 -d <"$T/kc/ebda-os-social-facebook" 2>/dev/null)" = "$sec" ] && ok "Keychain copy (base64) equals the secret" || no "Keychain copy differs"
grep -qE "EAAG|$APPSEC" "$T/out" && no "a token or the secret was printed: $(cat "$T/out")" || ok "no token or secret in the output"
grep -q "whisky11: Whisky 11 (222): OK, never expires; feed read: NO" "$T/out" && ok "reports the missing pages_read_user_content" || no "report: $(cat "$T/out")"
grep -qE "EAAG|$APPSEC" "$T/curl.log" && grep -q '^url = ' "$T/curl.log" && ok "tokens travel only in curl's stdin config (never argv)" || no "curl config not used"

rm -f "$T/npx.stdin"
printf '%s' "$USERTOK" | W11_EXP=1799999999 bash "$HERE/social-meta-token.sh" --stdin >"$T/out" 2>&1
grep -q "expires_at=1799999999" "$T/out" && python3 -I -c 'import json,sys; d=json.loads(open(sys.argv[1]).read()); assert list(d)==["ebda"]' "$T/npx.stdin" 2>/dev/null \
  && ok "an expiring Page token is refused and only the good Page is stored" || no "expiring token handling: $(cat "$T/out")"

rm -f "$T/npx.stdin"
printf '%s' "$USERTOK" | bash "$HERE/social-meta-token.sh" --dry-run --stdin >"$T/out" 2>&1
[ ! -f "$T/npx.stdin" ] && grep -q "dry run" "$T/out" && ok "--dry-run stores nothing" || no "--dry-run stored something"

printf '%s' "$USERTOK" >"$T/clip"; bash "$HERE/social-meta-token.sh" --dry-run </dev/null >"$T/out" 2>&1
grep -q "dry run" "$T/out" && [ ! -s "$T/clip" ] && ok "default reads the clipboard (works under \`! cmd\` with no stdin) and clears it" || no "clipboard path: $(cat "$T/out")"

echo "social-meta-token: $p passed, $f failed"
[ "$f" -eq 0 ]
