# shellcheck shell=bash
# emit-event.sh — local (trusted) event -> dispatcher. No HMAC (in-process, not over Telegram).
HERE_EE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE_EE/../dispatch.sh" 2>/dev/null || . "$HOME/.claude/scripts/dispatch.sh" 2>/dev/null || true
emit_event() { # <kind> <target-json>
  local kind="$1" tgt="$2" now id ev
  now="$(date +%s)"
  id="local-$kind-$(printf '%s' "$tgt" | shasum | cut -c1-12)"
  ev="$(python3 -c 'import json,sys;print(json.dumps({"id":sys.argv[1],"kind":sys.argv[2],"ts":int(sys.argv[3]),"target":json.loads(sys.argv[4])},separators=(",",":")))' "$id" "$kind" "$now" "$tgt")"
  # Pass the event as a PLAIN ARGUMENT — never eval/interpolate the payload (it can carry
  # external data, e.g. a repo slug/sha, so eval would be command-injectable). Default calls
  # the dispatch_event function directly; DISPATCH_CMD (a command path, for tests) gets $ev as $1.
  if [ -n "${DISPATCH_CMD:-}" ]; then
    ${DISPATCH_CMD} "$ev"
  else
    dispatch_event "$ev"
  fi
}