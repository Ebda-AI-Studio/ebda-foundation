#!/usr/bin/env bash
# The OS shares ONE Telegram bot (@EbdaAIStudiobot) with the tg-relay session, which is its single getUpdates consumer. Nothing else under os/ may
# poll it or register a webhook: a second consumer silently breaks the relay. Scans every tracked and untracked code/config file under os/
# (docs may describe the rule). Exempt: the two tests that name the strings in order to forbid them.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"; cd "$ROOT" || exit 1
fail=0
files="$( { git ls-files os; git ls-files --others --exclude-standard os; } | sort -u \
  | grep -E '\.(sh|bash|zsh|mjs|cjs|js|ts|py|plist|json|jsonc|yml|yaml|list|toml|tmpl)$' \
  | grep -vE '(^|/)(node_modules|dist)/|os/cloud/brain/test/send-only\.test\.ts$|os/ops/tests/telegram-send-only\.test\.sh$|package-lock\.json$')"
[ -n "$files" ] || { echo "FAIL: scanned nothing (guard against a broken file list)"; exit 1; }
hits="$(printf '%s\n' "$files" | while IFS= read -r f; do [ -f "$f" ] && grep -InEi 'getUpdates|setWebhook|deleteWebhook|getWebhookInfo' -- "$f" | sed "s|^|$f:|"; done)"
if [ -z "$hits" ]; then echo "PASS: no file under os/ polls Telegram or registers a webhook ($(printf '%s\n' "$files" | wc -l | tr -d ' ') files scanned)"
else echo "FAIL: Telegram polling / webhook registration found:"; printf '%s\n' "$hits"; fail=1; fi
# the scan has teeth: a planted file is caught
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
printf 'curl https://api.telegram.org/bot$T/getUpdates\n' > "$T/x.sh"
grep -qEi 'getUpdates' "$T/x.sh" && echo "PASS: the pattern matches a planted getUpdates call" || { echo "FAIL: pattern broken"; fail=1; }
exit "$fail"
