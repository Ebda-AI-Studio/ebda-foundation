#!/bin/sh
# Container entrypoint (root): run the one batch this container was started for, then exit (the container stops).
# No credential helper is installed: the hands hand GH_TOKEN to each git clone/push through a per-job askpass helper
# and to gh / the merge gate only, and Claude Code gets its token on fd 3 (lib/job.mjs).
set -eu
: "${HANDS_RUN_ID:?HANDS_RUN_ID missing}"
: "${GH_TOKEN:?GH_TOKEN missing}"
: "${CLAUDE_CODE_OAUTH_TOKEN:?CLAUDE_CODE_OAUTH_TOKEN missing}"
: "${HANDS_SANDBOX_USER:?HANDS_SANDBOX_USER missing}"
# F-I8 kernel side of the egress allowlist: the unprivileged uids may talk to loopback only (the allowlist proxy runs as root on
# 127.0.0.1); everything else they try is rejected. Needs CAP_NET_ADMIN. If it cannot be applied the run FAILS CLOSED
# (HANDS_EGRESS_REQUIRE_KERNEL=1, the image default) instead of running with open egress and only a proxy variable to stop it.
if [ "${HANDS_EGRESS_REQUIRE_KERNEL:-0}" = "1" ]; then
  ok=1
  for u in "${HANDS_SANDBOX_USER}" "${HANDS_TEST_USER:-}"; do
    [ -n "$u" ] || continue
    iptables -A OUTPUT -m owner --uid-owner "$u" -o lo -j ACCEPT && iptables -A OUTPUT -m owner --uid-owner "$u" -j REJECT || ok=0
  done
  [ "$ok" = 1 ] || { echo "hands: cannot apply the egress rules (iptables / CAP_NET_ADMIN); refusing to run with open egress" >&2; exit 3; }
fi
exec node /opt/ebda-os/cloud/hands/run-batch.mjs --run "$HANDS_RUN_ID"
