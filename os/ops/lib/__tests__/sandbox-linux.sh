#!/usr/bin/env bash
# FUNCTIONAL Landlock proof. Linux only; run under Docker from macOS:
#   docker run --rm -v "$PWD:/work:ro" alpine:3.20 sh /work/ops/lib/__tests__/sandbox-linux.sh
# Asserts the sandbox actually DENIES a write outside the allow-list. A unit test
# of the wrapper cannot prove that — only the kernel can.
set -eu
command -v gcc >/dev/null || apk add --no-cache gcc musl-dev >/dev/null 2>&1
SRC="${SRC:-/work/vendor/landlock-run/main.c}"
BIN=/tmp/landlock-run
gcc -O2 -static -o "$BIN" "$SRC"
echo "build: ok ($(wc -c < "$BIN") bytes) · kernel $(uname -r)"
"$BIN" --probe
mkdir -p /tmp/allowed /tmp/forbidden
"$BIN" --ro / --rw /tmp/allowed --rw /dev -- /bin/sh -c 'echo x > /tmp/allowed/f'
[ -f /tmp/allowed/f ] || { echo "FAIL: write inside the allow-list was blocked"; exit 1; }
echo "PASS: write inside --rw succeeded"
"$BIN" --ro / --rw /tmp/allowed --rw /dev -- /bin/sh -c 'echo x > /tmp/forbidden/f' 2>/dev/null || true
[ -f /tmp/forbidden/f ] && { echo "FAIL: write OUTSIDE the allow-list succeeded — not confined"; exit 1; }
echo "PASS: write outside --rw was denied and the file does not exist"
"$BIN" --ro / --rw /tmp/allowed --rw /dev -- /bin/sh -c 'head -1 /etc/hostname >/dev/null'
echo "PASS: reads under --ro / still work"
"$BIN" --ro / --rw /tmp/allowed --rw /dev -- /bin/sh -c 'echo x > /dev/null'
echo "PASS: /dev/null writable when /dev is granted (without it, real commands break)"
echo "sandbox-linux: all functional assertions passed"
