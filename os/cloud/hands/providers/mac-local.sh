#!/usr/bin/env bash
# mac-local hands runner (launchd: providers/launchd/com.ebda.os.hands-mac-local.plist, installed by Task 5).
# launchd only fires while the Mac is awake; one run at a time (mkdir lock); claims queued nightly work from the brain
# (POST /hands/claim, same usage guard as the container) and runs it here. Credentials come from OS_SERVICES_ENV
# (BRAIN_URL, HANDS_MAC_TOKEN, GH_TOKEN, HANDS_GIT_NAME, HANDS_GIT_EMAIL; Claude Code uses this Mac's own login) and the
# per-repo config from HANDS_CONFIG_FILE (default ~/.ebda-os.hands.json, shape os/config/hands.example.json).
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
OS_DIR="$(cd "$HERE/../.." && pwd)"
# shellcheck source=/dev/null
. "$OS_DIR/ops/lib/os-config.sh" && os_config_load
# shellcheck source=/dev/null
. "$OS_DIR/ops/lib/single-instance.sh"
single_instance hands-mac-local
# shellcheck source=/dev/null
[ -f "$OS_SERVICES_ENV" ] && set -a && . "$OS_SERVICES_ENV" && set +a
export HANDS_CONFIG_FILE="${HANDS_CONFIG_FILE:-$HOME/.ebda-os.hands.json}"
export HANDS_OS_HOME="${HANDS_OS_HOME:-$OS_DIR}"
export OS_STATE_DIR OS_REPO_SLUG
# F-06: the Mac runs on Ahmad's own login. The hands' Console key lives in the container ONLY, and no key that changes Claude's credential or
# endpoint may be in this environment (a key anywhere bills the API in -p mode). OS_SERVICES_ENV is `set -a` sourced and may hold other tools'
# keys: only the Claude-affecting ones stop the run (run-batch.mjs drops the others from every child).
for k in ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY AWS_BEARER_TOKEN_BEDROCK; do
  [ -z "${!k:-}" ] || { echo "hands-mac-local: REFUSED: $k is set in the environment (the Mac uses its own login; remove it from OS_SERVICES_ENV); nothing claimed" >&2; exit 4; }
done
# F-06b: the Mac has its OWN bearer; the container's per-run token and the HMAC key never exist here
for k in BRAIN_URL HANDS_MAC_TOKEN GH_TOKEN HANDS_GIT_NAME HANDS_GIT_EMAIL; do
  [ -n "${!k:-}" ] || { echo "hands-mac-local: $k unset (put it in OS_SERVICES_ENV); nothing claimed"; exit 0; }
done
[ -f "$HANDS_CONFIG_FILE" ] || { echo "hands-mac-local: no repo config at $HANDS_CONFIG_FILE; nothing claimed"; exit 0; }
export HANDS_WORKDIR="${HANDS_WORKDIR:-$HOME/.ebda-os-hands/work}"
# a crash or a launchd stop must not leave checkouts behind: sweep only job_* dirs (never the whole workdir)
cleanup() { find "$HANDS_WORKDIR" -mindepth 1 -maxdepth 1 -type d -name 'job_*' -exec rm -rf {} + 2>/dev/null; si_release hands-mac-local; }
trap cleanup EXIT
trap 'exit 143' TERM INT HUP
node "$HERE/run-batch.mjs" --claim --max "${HANDS_MAC_MAX_JOBS:-5}" --provider mac-local
