# shellcheck shell=bash
# lib/keychain.sh - read a macOS Keychain secret the way every OS script must.
#
# `security find-generic-password -w` prints a secret that contains a newline (an age identity file, a PEM key, a
# multi-line .env) as HEX, not as text. A script that pipes the raw output into a tool silently feeds it hex.
# keychain_get decodes that, but only when the decoded text looks like the expected secret, so a genuine hex token
# (a 64-char API key that happens to be hex) is left alone. Same rule as ebda-store scripts/cf/lib/keychain.mjs.
#
#   keychain_get <service> [account]     prints the secret (decoded when the rule fires) on stdout; non-zero when absent
#   keychain_decode [raw]                the pure rule: raw from $1 or stdin -> decoded-or-unchanged on stdout
#
# Rule: raw (trimmed) is non-empty, even-length, ^[0-9a-fA-F]+$, AND its decoded text contains a newline or starts with
# a known secret prefix (AGE-SECRET-KEY-1, -----BEGIN). Otherwise raw is returned unchanged.

_keychain_hex_to_text() { printf '%s' "$1" | perl -ne 'print pack("H*", $_)'; }

keychain_decode() {
  local raw decoded
  if [ $# -gt 0 ]; then raw="$1"; else raw="$(cat)"; fi
  raw="${raw#"${raw%%[![:space:]]*}"}"; raw="${raw%"${raw##*[![:space:]]}"}"   # trim only the ends
  if [ -n "$raw" ] && [ $(( ${#raw} % 2 )) -eq 0 ] && printf '%s' "$raw" | grep -Eq '^[0-9a-fA-F]+$'; then
    # sentinel: command substitution strips trailing newlines, which would hide a secret whose only newline is the last byte
    decoded="$(_keychain_hex_to_text "$raw"; printf x)"; decoded="${decoded%x}"
    case "$decoded" in
      *$'\n'*|AGE-SECRET-KEY-1*|-----BEGIN*)
        printf '%s\n' "$decoded" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}'
        return 0 ;;
    esac
  fi
  printf '%s\n' "$raw"
}

keychain_get() {
  local service="${1:?usage: keychain_get <service> [account]}" account="${2:-}" raw
  if ! command -v security >/dev/null 2>&1; then
    echo "keychain: 'security' not available on this host (macOS only)" >&2; return 1
  fi
  if [ -n "$account" ]; then raw="$(security find-generic-password -s "$service" -a "$account" -w 2>/dev/null)" || return 1
  else raw="$(security find-generic-password -s "$service" -w 2>/dev/null)" || return 1; fi
  keychain_decode "$raw"
}
