#!/usr/bin/env bash
# No script may call BSD `stat -f <fmt>` unless GNU `stat -c` is tried FIRST on the same line.
#
# WHY: on Linux, `stat -f` is "filesystem status", not "format". With a BSD format string it
# does NOT reliably fail, so the `|| fallback` never runs and the age/size math gets garbage
# (or 0). That made worktree-cleanup / workspace-hygiene treat every worktree as brand new on
# the self-hosted ubuntu runner while passing on macOS. GNU first: `stat -c %Y f || stat -f %m f`
# (BSD stat rejects -c, so macOS falls through correctly).
# Run: bash ops/tests/no-bsd-first-stat.test.sh   (SCAN_DIR overrides the tree, for the negative control)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCAN_DIR="${SCAN_DIR:-$HERE/..}"
pass=0; fail=0
bad="$(grep -rnE 'stat +-f' "$SCAN_DIR" --include='*.sh' \
  | grep -v '/tests/no-bsd-first-stat.test.sh:' \
  | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' \
  | grep -vE 'stat +-c[^|]*(\|\||;)[^|]*stat +-f' || true)"
if [ -z "$bad" ]; then echo "PASS: no BSD-first stat"; pass=1
else echo "FAIL: BSD-first stat (GNU \`stat -c\` must come first):"; printf '%s\n' "$bad"; fail=1; fi
echo; echo "no-bsd-first-stat: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
