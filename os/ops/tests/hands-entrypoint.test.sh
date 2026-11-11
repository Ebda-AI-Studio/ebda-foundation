#!/usr/bin/env bash
# hands container entrypoint (F-I8 / N-3a): the kernel egress rules cover IPv4 AND IPv6 for both unprivileged uids, and the run
# fails closed (exit 3, node never started) when either family cannot be locked down. iptables / ip6tables / node are fakes.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; EP="$HERE/../../cloud/hands/entrypoint.sh"
pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1 - got '$2' want '$3'"; fail=$((fail+1)); fi; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; mkdir -p "$BIN"
for t in iptables ip6tables; do
  cat > "$BIN/$t" <<S
#!/bin/sh
echo "$t \$*" >> "$TMP/rules.log"
[ "\${FAIL_${t}:-0}" = 1 ] && exit 1
exit 0
S
  chmod +x "$BIN/$t"
done
cat > "$BIN/node" <<S
#!/bin/sh
echo "node \$*" >> "$TMP/rules.log"
S
chmod +x "$BIN/node"
run() {  # extra env as args
  : > "$TMP/rules.log"
  env -i PATH="$BIN:/usr/bin:/bin" HANDS_RUN_ID=run1 GH_TOKEN=x ANTHROPIC_API_KEY=y HANDS_SANDBOX_USER=node HANDS_TEST_USER=tester \
    HANDS_EGRESS_REQUIRE_KERNEL=1 HANDS_IPV6_DISABLE_FILE="$TMP/no-such-file" "$@" sh "$EP" >"$TMP/out" 2>&1; echo $?
}
n(){ grep -c "$1" "$TMP/rules.log"; }

ok "all rules apply: exit 0 and node starts"          "$(run)" "0"
ok "  ...iptables got a rule per uid (node, tester)"  "$(n '^iptables .*--uid-owner node')$(n '^iptables .*--uid-owner tester')" "22"
ok "  ...ip6tables got the same rules per uid"        "$(n '^ip6tables .*--uid-owner node')$(n '^ip6tables .*--uid-owner tester')" "22"
ok "  ...ip6tables REJECTs non-loopback"              "$(grep -c '^ip6tables .*-j REJECT' "$TMP/rules.log")" "2"
ok "  ...node ran the batch"                          "$(n '^node .*run-batch')" "1"
ok "  ...and sent no refusal"                         "$(n 'report-refusal')" "0"
ok "ip6tables fails, IPv6 still enabled => exit 3"    "$(run FAIL_ip6tables=1)" "3"
ok "  ...the batch never started"                     "$(n 'run-batch')" "0"
ok "  ...the brain was told (P1 path)"                "$(n 'report-refusal')" "1"
ok "iptables fails => exit 3"                         "$(run FAIL_iptables=1)" "3"
ok "  ...the batch never started"                     "$(n 'run-batch')" "0"
ok "  ...the brain was told (P1 path)"                "$(n 'report-refusal')" "1"
echo 1 > "$TMP/ipv6-off"
ok "ip6tables fails but the kernel has IPv6 disabled => runs" "$(run FAIL_ip6tables=1 HANDS_IPV6_DISABLE_FILE="$TMP/ipv6-off")" "0"
echo 0 > "$TMP/ipv6-on"
ok "ip6tables fails and disable_ipv6=0 => exit 3"     "$(run FAIL_ip6tables=1 HANDS_IPV6_DISABLE_FILE="$TMP/ipv6-on")" "3"
ok "kernel enforcement off (Mac/dev): no rules, node runs" "$(run HANDS_EGRESS_REQUIRE_KERNEL=0)$(n '^ip6\?tables')" "00"
# RR-egress-roles: ptrace_scope is raised to 1 when the container allows it, and the value is logged either way (deploy-time check)
echo 0 > "$TMP/yama"
ok "yama 0 is raised to 1 when writable"  "$(run HANDS_YAMA_FILE="$TMP/yama" >/dev/null; cat "$TMP/yama")" "1"
ok "  ...and the value is logged"           "$(grep -c 'yama ptrace_scope=1' "$TMP/out")" "1"
ok "no yama in this kernel: logged, run continues" "$(run HANDS_YAMA_FILE="$TMP/none" | tr -d "\n"; grep -c "yama not present" "$TMP/out")" "01"
# cost audit: the credential for the mode must be present (api = the Console key, max = the OAuth token); GitHub: GH_TOKEN or per-owner App tokens
ok "api mode without its key: refused (non-zero), nothing started" "$(run ANTHROPIC_API_KEY= | sed 's/^[1-9].*/refused/')$(n 'run-batch')" "refused0"
ok "max mode needs the OAuth token, not the API key"     "$(run HANDS_CLAUDE_AUTH=max ANTHROPIC_API_KEY= | sed 's/^[1-9].*/refused/')$(n 'run-batch')" "refused0"
ok "max mode with its token starts"                      "$(run HANDS_CLAUDE_AUTH=max CLAUDE_CODE_OAUTH_TOKEN=o ANTHROPIC_API_KEY=)" "0"
ok "App tokens instead of GH_TOKEN are enough"           "$(run GH_TOKEN= 'HANDS_GH_TOKENS={"o":"t"}')" "0"
ok "neither GH_TOKEN nor App tokens: exit 2"             "$(run GH_TOKEN=)" "2"
echo "---"; echo "hands-entrypoint: $pass passed, $fail failed"; [ "$fail" = 0 ]
