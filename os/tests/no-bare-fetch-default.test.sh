#!/usr/bin/env bash
# The brain runs on workerd, where the global fetch throws "Illegal invocation" when called as a method (ctx.fetchImpl(url)).
# Every injectable default must be boundFetch (os/cloud/brain/src/bound-fetch.ts), never the bare global. Found 2026-11-11: all
# cloud watcher reads failed in production while the mocked tests stayed green.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
hits="$(grep -rnE 'typeof fetch = fetch\b|fetchImpl: fetch\b|fetchImpl = fetch\b' "$ROOT/os/cloud/brain/src" 2>/dev/null || true)"
if [ -n "$hits" ]; then echo "FAIL: bare global fetch used as an injectable default in the brain:"; echo "$hits"; exit 1; fi
echo "PASS: no bare fetch defaults in os/cloud/brain/src"
