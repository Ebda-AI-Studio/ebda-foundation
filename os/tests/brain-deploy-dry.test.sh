#!/usr/bin/env bash
# M-8: `deploy.sh --dry-run` must not leave wrangler.deploy.jsonc behind (its placeholder KV id and test values would be deployable).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; B="$ROOT/os/cloud/brain"
fail=0; ok() { echo "PASS: $1"; }; no() { echo "FAIL: $1"; fail=1; }
[ -x "$B/node_modules/.bin/wrangler" ] || { echo "SKIP: brain deps not installed"; exit 0; }
rm -f "$B/wrangler.deploy.jsonc"
HOME="$(mktemp -d)" bash "$B/scripts/deploy.sh" --dry-run >/dev/null 2>&1; rc=$?
[ ! -e "$B/wrangler.deploy.jsonc" ] && ok "dry run leaves no wrangler.deploy.jsonc behind (rc=$rc)" || no "dry run left wrangler.deploy.jsonc"
rm -f "$B/wrangler.deploy.jsonc"
[ "$fail" = 0 ] && echo "brain-deploy-dry: PASS" || echo "brain-deploy-dry: FAIL"; exit "$fail"
