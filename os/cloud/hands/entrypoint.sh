#!/bin/sh
# Container entrypoint (root): run the one batch this container was started for, then exit (the container stops).
# No credential helper is installed: the hands hand GH_TOKEN to each git clone/push through a per-job askpass helper
# and to gh / the merge gate only, and Claude Code gets its token on fd 3 (lib/job.mjs).
set -eu
: "${HANDS_RUN_ID:?HANDS_RUN_ID missing}"
# GitHub: a single GH_TOKEN (the PAT fallback) or per-owner App tokens (HANDS_GH_TOKENS); Claude: the Console API key (default api mode, with
# its spend-limit marker) or, in max mode, the OAuth token. run-batch.mjs enforces the exact-one-credential tripwire (exit 4).
[ -n "${GH_TOKEN:-}${HANDS_GH_TOKENS:-}" ] || { echo "hands: GH_TOKEN or HANDS_GH_TOKENS missing" >&2; exit 2; }
if [ "${HANDS_CLAUDE_AUTH:-api}" = "max" ]; then : "${CLAUDE_CODE_OAUTH_TOKEN:?CLAUDE_CODE_OAUTH_TOKEN missing}"; else : "${ANTHROPIC_API_KEY:?ANTHROPIC_API_KEY missing}"; fi
: "${HANDS_SANDBOX_USER:?HANDS_SANDBOX_USER missing}"
# F-I8 kernel side of the egress allowlist: the unprivileged uids may talk to loopback only (the allowlist proxy runs as root on
# 127.0.0.1); everything else they try is rejected, on IPv4 and IPv6. Needs CAP_NET_ADMIN. If it cannot be applied the run FAILS CLOSED
# (HANDS_EGRESS_REQUIRE_KERNEL=1, the image default) instead of running with open egress and only a proxy variable to stop it.
if [ "${HANDS_EGRESS_REQUIRE_KERNEL:-0}" = "1" ]; then
  # IPv4 AND IPv6 (N-3a): rules for one family only leave the other as an open path that ignores the proxy. ip6tables must apply, or the
  # kernel must have IPv6 switched off; neither => refuse to run.
  lock() {  # $1 = iptables | ip6tables
    for u in "${HANDS_SANDBOX_USER}" "${HANDS_TEST_USER:-}"; do
      [ -n "$u" ] || continue
      "$1" -A OUTPUT -m owner --uid-owner "$u" -o lo -j ACCEPT && "$1" -A OUTPUT -m owner --uid-owner "$u" -j REJECT || return 1
    done
  }
  ok=1
  lock iptables || ok=0
  if ! lock ip6tables; then
    [ "$(cat "${HANDS_IPV6_DISABLE_FILE:-/proc/sys/net/ipv6/conf/all/disable_ipv6}" 2>/dev/null || echo 0)" = "1" ] || ok=0
  fi
  if [ "$ok" != 1 ]; then
    echo "hands: cannot apply the egress rules (iptables + ip6tables / CAP_NET_ADMIN); refusing to run with open egress" >&2
    # tell the brain (P1), then exit 3: a silent exit would only show up as a failed run row
    node /opt/ebda-os/cloud/hands/lib/report-refusal.mjs "cannot apply the egress rules (iptables/ip6tables, CAP_NET_ADMIN)" || true
    exit 3
  fi
fi
# Yama (RR-egress-roles): with ptrace_scope >= 1 a child of Claude cannot read Claude's memory (its OAuth token). Raised when the container
# allows it; the value is logged either way so the first deploy shows whether it held (the host kernel owns it on some platforms).
y="${HANDS_YAMA_FILE:-/proc/sys/kernel/yama/ptrace_scope}"
if [ -e "$y" ]; then
  [ "$(cat "$y" 2>/dev/null || echo 0)" -ge 1 ] 2>/dev/null || echo 1 > "$y" 2>/dev/null || true
  echo "hands: yama ptrace_scope=$(cat "$y" 2>/dev/null || echo unknown)" >&2
else echo "hands: yama not present" >&2; fi
exec node /opt/ebda-os/cloud/hands/run-batch.mjs --run "$HANDS_RUN_ID"
