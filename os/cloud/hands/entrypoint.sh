#!/bin/sh
# Container entrypoint: wire git to gh's credential helper (GH_TOKEN from the env, never written to disk by us), then
# run the one batch this container was started for and exit. The container stops when run-batch exits.
set -eu
: "${HANDS_RUN_ID:?HANDS_RUN_ID missing}"
: "${GH_TOKEN:?GH_TOKEN missing}"
: "${CLAUDE_CODE_OAUTH_TOKEN:?CLAUDE_CODE_OAUTH_TOKEN missing}"
gh auth setup-git --hostname github.com
exec node /opt/ebda-os/cloud/hands/run-batch.mjs --run "$HANDS_RUN_ID"
