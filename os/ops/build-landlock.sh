#!/usr/bin/env bash
# build-landlock.sh — compile vendor/landlock-run for this host and install it.
#
# Linux only, by construction: Landlock is a Linux LSM. Run this at guest-image
# time on the umbra runners. Static musl build so it has no runtime deps.
# Verifies with --probe before installing: a binary that builds but cannot enforce
# is exactly the fail-open shape ops/lib/sandbox.sh exists to avoid.
set -euo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)/vendor/landlock-run/main.c"
DEST="${1:-$HOME/.claude/scripts/bin/landlock-run}"

[ "$(uname -s)" = "Linux" ] || { echo "build-landlock: Linux only (this is $(uname -s)). Landlock is a Linux LSM." >&2; exit 64; }
[ -f "$SRC" ] || { echo "build-landlock: missing $SRC" >&2; exit 1; }
command -v cc >/dev/null || command -v gcc >/dev/null || { echo "build-landlock: no C compiler" >&2; exit 1; }
CC="$(command -v gcc || command -v cc)"

mkdir -p "$(dirname "$DEST")"
tmp="$(mktemp)"
"$CC" -O2 -static -o "$tmp" "$SRC"
chmod +x "$tmp"
if ! "$tmp" --probe; then
  rm -f "$tmp"
  echo "build-landlock: built, but this kernel does NOT enforce Landlock — refusing to install." >&2
  echo "  Needs Linux >= 5.13 with CONFIG_SECURITY_LANDLOCK. Not installing a binary that" >&2
  echo "  would report success while confining nothing." >&2
  exit 1
fi
mv -f "$tmp" "$DEST"
echo "build-landlock: installed $DEST ($("$DEST" --probe))"
