#!/bin/sh
# Container entrypoint (root): run the one batch this container was started for, then exit (the container stops).
# No credential helper is installed: the hands hand GH_TOKEN to each git clone/push through a per-job askpass helper
# and to gh / the merge gate only, and Claude Code gets its token on fd 3 (lib/job.mjs).
set -eu
: "${HANDS_RUN_ID:?HANDS_RUN_ID missing}"
: "${GH_TOKEN:?GH_TOKEN missing}"
: "${CLAUDE_CODE_OAUTH_TOKEN:?CLAUDE_CODE_OAUTH_TOKEN missing}"
: "${HANDS_SANDBOX_USER:?HANDS_SANDBOX_USER missing}"
exec node /opt/ebda-os/cloud/hands/run-batch.mjs --run "$HANDS_RUN_ID"
