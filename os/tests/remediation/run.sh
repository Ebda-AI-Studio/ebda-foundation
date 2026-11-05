#!/usr/bin/env bash
set -uo pipefail
shopt -s nullglob
HERE="$(cd "$(dirname "$0")" && pwd)"
for t in "$HERE"/*_test.sh; do echo "== $(basename "$t") =="; bash "$t"; done
