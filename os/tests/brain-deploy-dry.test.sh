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
# AIOS-6: the brain watches the org its GitHub token is scoped to (brain-watchers.json OS_ORGS); OS_BRAIN_ORGS still overrides
out="$(HOME="$(mktemp -d)" env -u OS_BRAIN_ORGS bash "$B/scripts/deploy.sh" --dry-run 2>&1)"
grep -q 'env.OS_ORGS ("Ebda-AI-Studio")' <<<"$out" && ok "committed OS_ORGS is rendered (Ebda-AI-Studio only)" || no "OS_ORGS not rendered from brain-watchers.json"
out="$(HOME="$(mktemp -d)" OS_BRAIN_ORGS="o1 o2" bash "$B/scripts/deploy.sh" --dry-run 2>&1)"
grep -q 'env.OS_ORGS ("o1 o2")' <<<"$out" && ok "OS_BRAIN_ORGS overrides the committed orgs" || no "OS_BRAIN_ORGS override ignored"
# (wrangler truncates long values in its binding list, so the first 30 hex are matched)
# the deploy stamps the git commit into the build (/health returns it): "is it deployed?" is answered by the running Worker, not a wrangler version id
sha="$(git -C "$B" rev-parse HEAD 2>/dev/null)"
out="$(HOME="$(mktemp -d)" bash "$B/scripts/deploy.sh" --dry-run 2>&1)"
[ -n "$sha" ] && grep -Fq "env.GIT_COMMIT (\"${sha:0:30}" <<<"$out" && ok "deploy.sh stamps the git commit into GIT_COMMIT" || no "deploy.sh does not set GIT_COMMIT to the current commit"
rm -f "$B/wrangler.deploy.jsonc"
[ "$fail" = 0 ] && echo "brain-deploy-dry: PASS" || echo "brain-deploy-dry: FAIL"; exit "$fail"
