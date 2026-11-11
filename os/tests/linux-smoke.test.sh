#!/usr/bin/env bash
# Linux smoke for the OS scripts: every os/ops shell script must parse (bash -n) and survive `--help` on Linux without a
# bash-level error (syntax error, bad substitution, unbound variable). macOS-only scripts (launchctl, osascript, the
# Keychain `security` tool, sw_vers, apple `container`) are parsed but their --help is skipped.
# Run in a container so nothing can touch a real HOME:
#   container run --rm -v "$PWD":/w:ro -w /w node:22 bash os/tests/linux-smoke.test.sh
# --help runs with a throwaway HOME, no network config, and a 10s cap per script.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
TMPH="$(mktemp -d)"; trap 'rm -rf "$TMPH"' EXIT
export HOME="$TMPH" GIT_CONFIG_GLOBAL="$TMPH/.gitconfig" GIT_CONFIG_NOSYSTEM=1 OS_STATE_DIR="$TMPH/state" TERM=dumb
TO=""; command -v timeout >/dev/null 2>&1 && TO="timeout 10"
fail=0; parsed=0; helped=0; skipped=0
MAC_RE='launchctl|osascript|security find-generic-password|sw_vers|xcrun|^[[:space:]]*container (run|list|system)|diskutil|pmset'

while IFS= read -r f; do
  parsed=$((parsed+1))
  if ! out=$(bash -n "$f" 2>&1); then echo "FAIL parse: $f: $out"; fail=$((fail+1)); continue; fi
  # --help only for top-level entrypoints (os/ops/*.sh); libs are sourced, hooks read stdin
  case "$f" in os/ops/*.sh) ;; *) continue ;; esac
  case "$(basename "$f")" in run-tests.sh|install.sh|uninstall.sh|bootstrap.sh|install-hooks.sh|install-agents.sh) skipped=$((skipped+1)); continue ;; esac
  if grep -Eq "$MAC_RE" "$f"; then skipped=$((skipped+1)); continue; fi
  helped=$((helped+1))
  out=$($TO bash "$f" --help </dev/null 2>&1 | head -50)
  # A missing positional argument ($1/$2: unbound variable) is a usage error, not a Linux incompatibility.
  bad=$(printf '%s\n' "$out" | grep -E 'syntax error|bad substitution|unbound variable|unexpected token' | grep -Ev '\$[0-9]+: unbound variable')
  if [ -n "$bad" ]; then
    echo "FAIL --help: $f"; printf '%s\n' "$bad" | head -3; fail=$((fail+1))
  fi
done < <(find os -type f -name '*.sh' -not -path '*/__tests__/*' -not -path 'os/tests/*' -not -path 'os/ops/tests/*' | LC_ALL=C sort)

for t in os/tests/*.sh os/ops/tests/*.sh os/ops/lib/__tests__/*.sh os/tests/remediation/*.sh; do
  [ -f "$t" ] || continue
  parsed=$((parsed+1))
  out=$(bash -n "$t" 2>&1) || { echo "FAIL parse: $t: $out"; fail=$((fail+1)); }
done

echo "linux-smoke: $parsed parsed, $helped --help ran, $skipped skipped (macOS-only/installers), $fail failing"
[ "$fail" -eq 0 ]
