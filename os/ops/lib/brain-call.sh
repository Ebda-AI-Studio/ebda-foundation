# shellcheck shell=bash
# lib/brain-call.sh - authenticated calls to the brain from the Mac, without ever printing INGEST_TOKEN.
#   . lib/os-config.sh && os_config_load && . lib/brain-call.sh
#   brain_call METHOD PATH [curl args...]     # body to stdout; returns curl's exit code; HTTP >=400 -> exit 22
# Token + URL come from $OS_SERVICES_ENV exactly like lib/brain-post.sh. The host is resolved with `dig @8.8.8.8` and pinned with
# `curl --resolve` because the ISP blocks Cloudflare IPs on the system resolver. The token goes to curl via a 0600 config file, never argv.
. "$(dirname "${BASH_SOURCE[0]}")/brain-post.sh"

brain_call() {
  local method="${1:?method}" path="${2:?path}"; shift 2
  _brain_env
  local base="${OS_BRAIN_URL:-https://os.ebda.app}"; base="${base%/}"
  [ -n "${INGEST_TOKEN:-}" ] || { echo "brain-call: INGEST_TOKEN not found in \$OS_SERVICES_ENV" >&2; return 2; }
  local host="${base#https://}"; host="${host%%/*}"
  local ip; ip="$(dig +short +time=3 +tries=1 @8.8.8.8 "$host" A 2>/dev/null | grep -E '^[0-9.]+$' | head -1)"
  local cfg; cfg="$(mktemp)"; chmod 600 "$cfg"
  printf 'header = "Authorization: Bearer %s"\n' "$INGEST_TOKEN" > "$cfg"
  local resolve=(); [ -n "$ip" ] && resolve=(--resolve "$host:443:$ip")
  curl -fsS -m "${BRAIN_CALL_TIMEOUT:-30}" -K "$cfg" "${resolve[@]}" -X "$method" "$@" "$base$path"
  local rc=$?
  rm -f "$cfg"
  return "$rc"
}
