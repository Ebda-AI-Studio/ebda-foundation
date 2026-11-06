#!/usr/bin/env bash
# Superseded by os/install.sh (Mac-local jobs only; the always-on part is the brain Worker). Kept so old muscle memory still works.
exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/os/install.sh" "$@"
