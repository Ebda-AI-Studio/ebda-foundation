#!/usr/bin/env bash
# Ebda AI OS - brain-send.sh: send Ahmad a Telegram message or file through the brain (POST /api/telegram/send).
#   brain-send.sh text "message"            (<= 4000 chars; "-" reads stdin)
#   brain-send.sh file PATH [caption]       (<= 10 MB; caption <= 1024 chars goes with the file)
# Never prints the token (lib/brain-call.sh). Exit 0 sent, 1 refused, 2 usage/config.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/os-config.sh
. "$HERE/lib/os-config.sh" 2>/dev/null && os_config_load 2>/dev/null || true
# shellcheck source=lib/brain-call.sh
. "$HERE/lib/brain-call.sh"
post() { brain_call POST /api/telegram/send -H 'content-type: application/json' --data-binary @-; }
case "${1:-}" in
  text)
    msg="${2:-}"; [ "$msg" = "-" ] && msg="$(cat)"
    [ -n "$msg" ] || { echo "usage: brain-send.sh text \"message\"" >&2; exit 2; }
    python3 -I -c 'import json,sys; print(json.dumps({"text": sys.argv[1]}))' "$msg" | post || exit 1 ;;
  file)
    f="${2:-}"; [ -f "$f" ] || { echo "brain-send.sh: no such file: $f" >&2; exit 2; }
    [ "$(wc -c < "$f")" -le 10485760 ] || { echo "brain-send.sh: file over 10 MB" >&2; exit 2; }
    python3 -I -c 'import json,sys,base64,os
p=sys.argv[1]
print(json.dumps({"document_base64": base64.b64encode(open(p,"rb").read()).decode(), "filename": os.path.basename(p), **({"text": sys.argv[2]} if len(sys.argv)>2 and sys.argv[2] else {})}))' "$f" "${3:-}" | post || exit 1 ;;
  *) sed -n 2,6p "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
echo
