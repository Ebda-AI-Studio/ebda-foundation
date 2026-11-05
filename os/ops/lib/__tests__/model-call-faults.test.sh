#!/usr/bin/env bash
# A model-calling script must distinguish "the model said nothing useful" from
# "the task failed", and must never consume its input on a failed call. These are
# the first behavioural tests the OS has for a model call at all — before
# CLAUDE_BIN existed the seam could not be reached offline.
# Run: bash ops/lib/__tests__/model-call-faults.test.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
_pass=0; _fail=0
ok() { echo "PASS: $1"; _pass=$((_pass+1)); }
no() { echo "FAIL: $1"; _fail=$((_fail+1)); }
# shellcheck source=/dev/null
. "$ROOT/lib/claude-stub.sh"

setup() {                    # $1 = mode -> prints the fake HOME
  h="$(mktemp -d)"
  mkdir -p "$h/.claude/instincts/traces" "$h/bin" "$h/proj"
  git -C "$h/proj" init -q 2>/dev/null
  git -C "$h/proj" remote add origin https://example.com/p.git 2>/dev/null
  for i in $(seq 1 20); do
    printf '12:00:%02d\t%s\tBash\tcmd %s\n' "$i" "$h/proj" "$i" >> "$h/.claude/instincts/traces/s.trace"
  done
  make_claude_stub "$h/bin" "$1" >/dev/null
  printf '%s' "$h"
}
store_rows() { wc -l < "$1/.claude/instincts/store.jsonl" 2>/dev/null | tr -d ' ' || echo 0; }
traces_left() { find "$1/.claude/instincts/traces" -maxdepth 1 -name '*.trace' 2>/dev/null | wc -l | tr -d ' '; }

# ---- ok: extracts and consumes the traces ----
H="$(setup ok)"
HOME="$H" CLAUDE_BIN="$H/bin/claude" bash "$ROOT/instinct-extract.sh" >/dev/null 2>&1
[ "$(store_rows "$H")" -ge 1 ] && ok "ok: an instinct is stored" || no "ok: an instinct is stored"
[ "$(traces_left "$H")" = "0" ] && ok "ok: traces are archived after a good run" || no "ok: traces are archived after a good run"
rm -rf "$H"

# ---- empty: must KEEP the traces, not consume them for nothing ----
H="$(setup empty)"
HOME="$H" CLAUDE_BIN="$H/bin/claude" bash "$ROOT/instinct-extract.sh" >/dev/null 2>&1
[ "$(store_rows "$H")" = "0" ] && ok "empty: nothing is stored" || no "empty: nothing is stored"
[ "$(traces_left "$H")" = "1" ] && ok "empty: traces are KEPT for the next run" || no "empty: traces are KEPT for the next run"
rm -rf "$H"

# ---- ratelimit: a provider throttle must not be recorded as extracted content ----
H="$(setup ratelimit)"
HOME="$H" CLAUDE_BIN="$H/bin/claude" bash "$ROOT/instinct-extract.sh" >/dev/null 2>&1
[ "$(store_rows "$H")" = "0" ] && ok "ratelimit: nothing is stored" || no "ratelimit: nothing is stored"
[ "$(traces_left "$H")" = "1" ] && ok "ratelimit: traces are KEPT" || no "ratelimit: traces are KEPT"
rm -rf "$H"

# ---- crash: same posture as a rate limit ----
H="$(setup crash)"
HOME="$H" CLAUDE_BIN="$H/bin/claude" bash "$ROOT/instinct-extract.sh" >/dev/null 2>&1
[ "$(traces_left "$H")" = "1" ] && ok "crash: traces are KEPT" || no "crash: traces are KEPT"
rm -rf "$H"

# ---- malformed: prose with no JSON must yield NO instincts, never a junk row ----
H="$(setup malformed)"
HOME="$H" CLAUDE_BIN="$H/bin/claude" bash "$ROOT/instinct-extract.sh" >/dev/null 2>&1
[ "$(store_rows "$H")" = "0" ] && ok "malformed: no junk row is stored" || no "malformed: no junk row is stored"
rm -rf "$H"

# ---- partial: a truncated array must not be salvaged into a half-instinct ----
H="$(setup partial)"
HOME="$H" CLAUDE_BIN="$H/bin/claude" bash "$ROOT/instinct-extract.sh" >/dev/null 2>&1
[ "$(store_rows "$H")" = "0" ] && ok "partial: a truncated array yields nothing" || no "partial: a truncated array yields nothing"
python3 -c "
import json,sys
p='$H/.claude/instincts/store.jsonl'
import os
if os.path.exists(p):
    for l in open(p):
        if l.strip(): json.loads(l)   # every stored line must still be valid JSON
" && ok "partial: the store contains no invalid JSON" || no "partial: the store contains no invalid JSON"
rm -rf "$H"

echo; echo "model-call-faults: $_pass passed, $_fail failed"
[ "$_fail" -eq 0 ]
