#!/usr/bin/env bash
#
# agent-dispatch.sh — run a free-text request from Telegram as a real agent job.
#
# THE GAP THIS CLOSES
# -------------------
# auto-fix-telegram-daemon.sh has long-polled Telegram since 2026-07-19 with
# 1-3s latency, but its `*)` branch did this and only this:
#
#     *)  log "$FROM non-command msg: $TEXT" ;;
#
# Every free-text message was written to a log file and dropped — 19 of them
# before Ahmad stopped trying in May 2026. The channel was built; nothing was
# listening behind it.
#
# This script is what listens. Telegram message -> `claude -p` in the right
# repo -> result back to Telegram.
#
# DESIGN CONSTRAINTS (each one is a rule from CLAUDE.md, not a preference)
#   * Never more than 1 concurrent `claude -p` — token discipline. Enforced by
#     an atomic mkdir lock with stale-PID recovery.
#   * Runs detached. `claude -p` takes minutes; the daemon's 30s poll loop must
#     never block on it or Telegram updates back up.
#   * Every job is logged with its prompt, cwd, exit code and duration.
#   * A hard timeout — a hung agent must not hold the lock forever.
#
# Usage:  agent-dispatch.sh "<free text request>" [<from-user>]

# shellcheck source=lib/os-config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/os-config.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-config.sh" 2>/dev/null || true
command -v os_config_load >/dev/null 2>&1 && os_config_load
set -uo pipefail

STATE_DIR="${WHISKY_STATE_DIR:-$HOME/.whisky-os-state}"
LOG_FILE="$HOME/Library/Logs/agent-dispatch.log"
LOCK_DIR="$STATE_DIR/agent-dispatch.lock"
CWD_FILE="$STATE_DIR/agent-cwd"
JOBS_LOG="$STATE_DIR/agent-jobs.jsonl"

# Telegram creds live in a local env file (chmod 600, never committed). They were hard-coded
# defaults here until 2026-10-08; that token sits in git history and must be rotated.
TG_ENV="${TG_ENV:-$OS_SERVICES_ENV}"
# shellcheck source=/dev/null
[ -f "$TG_ENV" ] && { set -a; . "$TG_ENV"; set +a; }
: "${TELEGRAM_BOT_TOKEN:?TELEGRAM_BOT_TOKEN unset — put it in $TG_ENV}"
: "${TELEGRAM_ALERT_CHAT_ID:?TELEGRAM_ALERT_CHAT_ID unset — put it in $TG_ENV}"

# `claude -p` can legitimately run long (investigation + edits + verify), but a
# hung one must not wedge the queue. 25 min is above the slowest observed
# auto-fix investigation (~15 min) with headroom.
AGENT_TIMEOUT_SECONDS="${AGENT_TIMEOUT_SECONDS:-1500}"

mkdir -p "$(dirname "$LOG_FILE")" "$STATE_DIR"

log() { echo "[$(date '+%Y-%m-%dT%H:%M:%S')] $*" >> "$LOG_FILE"; }

# Telegram hard-caps a message at 4096 chars. Split on line boundaries where
# possible so code blocks and lists stay readable.
send() {
  local text="$1" chunk
  while [[ -n "$text" ]]; do
    chunk="${text:0:3500}"
    if [[ ${#text} -gt 3500 ]]; then
      # back off to the last newline so we don't cut mid-line
      local nl="${chunk%$'\n'*}"
      [[ -n "$nl" && ${#nl} -gt 500 ]] && chunk="$nl"
    fi
    curl -sS -m 20 -X POST \
      "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      -d chat_id="${TELEGRAM_ALERT_CHAT_ID}" \
      -d disable_web_page_preview=true \
      --data-urlencode text="$chunk" >/dev/null 2>&1
    text="${text:${#chunk}}"
    text="${text#$'\n'}"
  done
}

TEXT="${1:-}"
FROM="${2:-telegram}"

if [[ -z "$TEXT" ]]; then
  log "empty request, nothing to do"
  exit 0
fi

# ---------------------------------------------------------------- usage fan-out stop (2026-10-26)
# usage-sentinel.sh writes usage/fanout-stop at >= 80 % weekly use. A new agent job is refused while it exists
# (deterministic, no model involved). AGENT_DISPATCH_IGNORE_STOP=1 is the explicit, logged override.
USAGE_STOP_FILE="${USAGE_STATE:-$STATE_DIR/usage}/fanout-stop"
if [[ -e "$USAGE_STOP_FILE" ]]; then
  if [[ "${AGENT_DISPATCH_IGNORE_STOP:-0}" == 1 ]]; then
    log "fanout-stop present but AGENT_DISPATCH_IGNORE_STOP=1 - proceeding: $TEXT"
  else
    log "refused (fanout-stop): $TEXT"
    send "Weekly usage is at the fan-out limit ($(tr '\n' ' ' < "$USAGE_STOP_FILE")). Your request was NOT run. Lift with /resume (or remove $USAGE_STOP_FILE), then send it again."
    exit 0
  fi
fi

# ---------------------------------------------------------------- lock
# mkdir is atomic on macOS; a plain -f test would race two arriving messages.
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  HOLDER=$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "?")
  if [[ "$HOLDER" != "?" ]] && ! kill -0 "$HOLDER" 2>/dev/null; then
    log "stale lock from dead pid $HOLDER — reclaiming"
    rm -rf "$LOCK_DIR"; mkdir "$LOCK_DIR" 2>/dev/null || true
  else
    RUNNING=$(cat "$LOCK_DIR/prompt" 2>/dev/null | head -c 120)
    log "busy (pid $HOLDER) — rejected: $TEXT"
    send "⏳ Busy — an agent job is already running:
\"$RUNNING\"

Your request was NOT queued. Send it again when I report back, or /kill to stop the current one."
    exit 0
  fi
fi
echo "$$" > "$LOCK_DIR/pid"
echo "$TEXT" > "$LOCK_DIR/prompt"
trap 'rm -rf "$LOCK_DIR"' EXIT

# ---------------------------------------------------------------- cwd
# Three ways the repo gets chosen, in priority order:
#   1. INFERRED from the message itself ("fix the CORS bug in fwb")
#   2. STICKY, from the last `/cd` (survives across messages)
#   3. the projects root, where the agent can search across everything
#
# Inference exists because typing `/cd` before every request is exactly the
# manual overhead this whole thing is meant to remove. It only fires on a
# confident whole-word match; anything ambiguous falls through to sticky.
PROJECTS="$OS_PROJECTS_DIR"
INFERRED=""
LOWER=$(echo "$TEXT" | tr '[:upper:]' '[:lower:]')

# alias|path — first whole-word hit wins. Longer/more specific aliases first so
# "ebda-store" is not shadowed by "ebda" by a looser match.
while IFS='|' read -r alias rel; do
  [[ -z "$alias" ]] && continue
  if echo "$LOWER" | grep -qE "(^|[^a-z0-9])${alias}([^a-z0-9]|$)"; then
    for _d in "$PROJECTS"/$rel; do [[ -d "$_d" ]] && { INFERRED="$_d"; break 2; }; done
  fi
done <<ALIASES
ebda-store|$OS_ORG/internal-projects/ebda-store
ebda-whatsapp|$OS_ORG/internal-projects/ebda-whatsapp
whatsapp|$OS_ORG/internal-projects/ebda-whatsapp
ebda-studio|$OS_ORG/internal-projects/ebda-studio
ebda-foundation|$OS_ORG/internal-projects/ebda-foundation
foundation|$OS_ORG/internal-projects/ebda-foundation
digital-card|Personal/projects/digital-card
mypovonai|Personal/projects/mypovonai
zero|*/internal-projects/zero
ebda|$OS_ORG/internal-projects/ebda-store
ALIASES

if [[ -n "$INFERRED" ]]; then
  CWD="$INFERRED"
  CWD_SOURCE="inferred from your message"
else
  CWD="$PROJECTS"
  if [[ -f "$CWD_FILE" ]]; then
    STICKY=$(cat "$CWD_FILE" 2>/dev/null)
    [[ -d "$STICKY" ]] && { CWD="$STICKY"; CWD_SOURCE="sticky (/cd)"; }
  fi
  [[ "${CWD_SOURCE:-}" == "" ]] && CWD_SOURCE="projects root — agent will search"
fi
[[ -d "$CWD" ]] || { CWD="$PROJECTS"; CWD_SOURCE="fallback"; }

START=$(date +%s)
log "dispatch from=$FROM cwd=$CWD :: $TEXT"
send "🤖 Working in \`$(basename "$CWD")\` ($CWD_SOURCE)…
$TEXT"

# ------------------------------------------------------------- context
# THE BUG THIS FIXES
# ------------------
# On 2026-08-11 Ahmad read three Whisky OS alerts in Telegram and replied
# "What is this tell me ?". The daemon ran, verbatim:
#
#     claude -p "What is this tell me ?"
#
# in the projects root. The agent had no alerts, no OS state and no prior
# messages — "this" referred to something it could not see — so it searched the
# whole projects tree looking for what he meant and was killed at 25 minutes.
# It was never going to succeed: the question was unanswerable as delivered.
#
# Telegram is a CONVERSATION. Every message he sends is a reply to something,
# usually to an alert the OS itself just sent. Shipping the message without the
# thing it refers to guarantees this failure for every pronoun he ever types.
#
# So: attach what the OS currently knows. Cheap (a few hundred tokens of local
# JSON), and it is exactly the material a question like "what is this" needs.
build_context() {
  python3 - "$STATE_DIR" <<'PY' 2>/dev/null || true
import json, os, sys, glob

state = sys.argv[1]
out = []

# 1. Whatever the OS is currently unhappy about — this is what an alert-reply
#    almost always refers to. Only non-ok tiles: a wall of green is noise.
bad = []
for f in sorted(glob.glob(os.path.join(state, "*-status.json"))):
    try:
        d = json.load(open(f))
    except Exception:
        continue
    if str(d.get("ok", "")).lower() in ("true", "1"):
        continue
    name = os.path.basename(f).replace("-status.json", "")
    bad.append(f"  - {name} [{d.get('ok')}]: {str(d.get('summary',''))[:200]}")
if bad:
    out.append("SUBSYSTEMS NOT OK RIGHT NOW:\n" + "\n".join(bad[:14]))

# 2. The alert digest — the literal text of the Telegram messages he just read.
dg = os.path.join(state, "alert-digest.json")
if os.path.exists(dg):
    try:
        d = json.load(open(dg))
        for bucket in ("new", "surging", "changed", "ongoing_top"):
            rows = d.get(bucket) or []
            if not rows:
                continue
            lines = [f"  - [{r.get('count')}x] {str(r.get('title',''))[:130]}" for r in rows[:6]]
            out.append(f"ALERTS ({bucket}):\n" + "\n".join(lines))
    except Exception:
        pass

print("\n\n".join(out)[:4000])
PY
}

CONTEXT="$(build_context)"

# A directive, not just data. Without it the agent treats a one-line question as
# an open-ended engineering task and burns the entire timeout budget.
read -r -d '' PREAMBLE <<PREAMBLE_EOF || true
You are answering a Telegram message from Ahmad. He is on his phone.

Rules for this reply:
- ANSWER FIRST. If he asked a question, answer it in the first sentence.
- Keep it under ~1500 characters. Plain text, no markdown tables.
- If he is pointing at something vague ("this", "it", "that one"), resolve it
  from the CURRENT OS STATE below — that is almost certainly what he means.
- Do NOT start a refactor, a migration, or a repo-wide audit unless he clearly
  asked for one. A vague message is a question, not a work order.
- If you genuinely cannot tell what he means, say so in one line and list the
  2-3 things he might mean. Do not go searching the filesystem for it.

=== CURRENT OS STATE (live, from ~/.whisky-os-state) ===
${CONTEXT:-（no state files readable）}
=== END OS STATE ===

Ahmad's message:
PREAMBLE_EOF

FULL_PROMPT="$PREAMBLE
$TEXT"

# ---------------------------------------------------------------- run
# No --allowedTools restriction: unlike the auto-fix path (which runs unattended
# on a machine-detected failure), this is Ahmad explicitly asking for something,
# so the agent needs its full toolset. The human IS in the loop — he sent the
# message.
OUT_FILE=$(mktemp /tmp/agent-dispatch.XXXXXX)

# macOS ships NO `timeout` — it's `gtimeout` from MacPorts/coreutils, and it may
# not be installed at all. A bare `timeout ...` here fails with exit 127 and
# every single job would come back "❌ Agent exited 127" without ever running
# the agent. Resolve it, and fall back to a watchdog if neither exists.
TIMEOUT_BIN=""
for c in timeout gtimeout /opt/local/bin/gtimeout /opt/homebrew/bin/gtimeout; do
  command -v "$c" >/dev/null 2>&1 && { TIMEOUT_BIN="$c"; break; }
done

if [[ -n "$TIMEOUT_BIN" ]]; then
  ( cd "$CWD" && "$TIMEOUT_BIN" "$AGENT_TIMEOUT_SECONDS" claude -p "$FULL_PROMPT" ) >"$OUT_FILE" 2>&1
  RC=$?
else
  # Portable fallback: run detached, kill it if it outlives the budget.
  ( cd "$CWD" && claude -p "$FULL_PROMPT" ) >"$OUT_FILE" 2>&1 &
  AGENT_PID=$!
  ( sleep "$AGENT_TIMEOUT_SECONDS"; kill -0 "$AGENT_PID" 2>/dev/null && kill -9 "$AGENT_PID" 2>/dev/null ) &
  WATCHDOG_PID=$!
  wait "$AGENT_PID"; RC=$?
  kill "$WATCHDOG_PID" 2>/dev/null
  # A SIGKILLed agent surfaces as 137; normalise to 124 so the timeout branch
  # below reports it the same way regardless of which path ran.
  (( RC == 137 )) && RC=124
fi
END=$(date +%s)
DUR=$((END - START))

OUT=$(cat "$OUT_FILE"); rm -f "$OUT_FILE"

# Append-only job record so the loop is auditable after the fact.
python3 - "$JOBS_LOG" "$FROM" "$CWD" "$RC" "$DUR" "$TEXT" <<'PY' 2>/dev/null || true
import json, sys, datetime
path, frm, cwd, rc, dur, text = sys.argv[1:7]
rec = {"ts": datetime.datetime.now().isoformat(timespec="seconds"),
       "from": frm, "cwd": cwd, "rc": int(rc), "seconds": int(dur), "prompt": text}
with open(path, "a") as f:
    f.write(json.dumps(rec, ensure_ascii=False) + "\n")
PY

# Surface the agent loop in Force AI Ops (:7717 aggregator reads *-status.json
# from the state dir). Without this the whole Telegram->agent loop is invisible
# in the one place Ahmad looks for "where are we".
python3 - "$STATE_DIR/agent-status.json" "$JOBS_LOG" "$RC" "$DUR" "$TEXT" "$CWD" <<'PY' 2>/dev/null || true
import json, sys, datetime, os
status_path, jobs_log, rc, dur, text, cwd = sys.argv[1:7]
rc, dur = int(rc), int(dur)

total = fails = 0
if os.path.exists(jobs_log):
    with open(jobs_log) as f:
        for line in f:
            try:
                r = json.loads(line)
            except Exception:
                continue
            total += 1
            if r.get("rc"): fails += 1

ok = "true" if rc == 0 else ("warn" if rc == 124 else "false")
verdict = {0: "ok"}.get(rc, "timed out" if rc == 124 else f"exit {rc}")
json.dump({
    "ok": ok,
    "summary": f"last job {verdict} in {dur//60}m{dur%60:02d}s · {total} total, {fails} failed",
    "detail": {
        "last_prompt": text[:160],
        "last_repo": os.path.basename(cwd),
        "last_rc": rc,
        "last_seconds": dur,
        "jobs_total": total,
        "jobs_failed": fails,
    },
    "checked_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}, open(status_path, "w"), indent=1)
PY

if (( RC == 124 )); then
  log "TIMEOUT after ${AGENT_TIMEOUT_SECONDS}s :: $TEXT"
  # `claude -p` buffers its answer and prints at the end, so a SIGKILLed run
  # almost always leaves $OUT EMPTY. The old message promised "Partial output:"
  # and then showed nothing — which reads as a truncated answer rather than as
  # "there was never any output", two different states collapsed into one.
  if [[ -n "${OUT// /}" ]]; then
    send "⏱ Timed out after $((AGENT_TIMEOUT_SECONDS / 60)) min and was killed.

What it had produced before the kill:
${OUT: -2500}"
  else
    send "⏱ Timed out after $((AGENT_TIMEOUT_SECONDS / 60)) min and was killed — it produced no output at all (claude -p only prints when it finishes, so there is nothing partial to show).

Ran in: $(basename "$CWD") ($CWD_SOURCE)
Your message: $TEXT

That usually means the request was too open-ended to land in one pass. Try naming the repo and the specific thing, e.g. \"in fwb, why is the CORS error firing\"."
  fi
elif (( RC != 0 )); then
  log "FAILED rc=$RC in ${DUR}s :: $TEXT"
  send "❌ Agent exited $RC after ${DUR}s.

${OUT: -2500}"
else
  log "OK in ${DUR}s :: $TEXT"
  send "✅ Done in $((DUR / 60))m $((DUR % 60))s

$OUT"
fi
