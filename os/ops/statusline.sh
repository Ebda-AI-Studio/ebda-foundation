#!/bin/bash
# Claude Code statusline — readable at a glance.
# stdin: session JSON · stdout: single line.
#
#   📁 project · 🌿 branch · ✓ @ahmad · 🤖 model · 🧠 ctx · ⚙️ bg · 💰 $cost · 🔋 N% · 🕐 5:32 AM
#
# Each section is a single icon + value. Drop anything empty.

set -u

# ── colors ───────────────────────────────────────────────────────────
R=$'\033[0m'
DIM=$'\033[2m'
BOLD=$'\033[1m'
CYAN=$'\033[38;5;51m'
GREEN=$'\033[38;5;46m'
YELLOW=$'\033[38;5;220m'
RED=$'\033[38;5;196m'
BLUE=$'\033[38;5;39m'
ORANGE=$'\033[38;5;208m'
GRAY=$'\033[38;5;245m'
SEP=" ${GRAY}·${R} "

# ── parse stdin ──────────────────────────────────────────────────────
in=$(cat)
cwd=$(printf '%s' "$in" | jq -r '.workspace.current_dir // .cwd // ""')
proj=$(printf '%s' "$in" | jq -r '.workspace.project_dir // .cwd // ""')
mid=$(printf '%s' "$in" | jq -r '.model.id // ""')
mname=$(printf '%s' "$in" | jq -r '.model.display_name // ""')
cost=$(printf '%s' "$in" | jq -r '.cost.total_cost_usd // 0')
transcript=$(printf '%s' "$in" | jq -r '.transcript_path // ""')
session_id=$(printf '%s' "$in" | jq -r '.session_id // ""')

# ── 📁 PROJECT ───────────────────────────────────────────────────────
proj_name=$(basename "$proj" 2>/dev/null)
[ -z "$proj_name" ] && proj_name="$(basename "$cwd")"
proj_section="${CYAN}📁 ${BOLD}${proj_name}${R}"
if [ -n "$proj" ] && [ "$cwd" != "$proj" ]; then
  rel=${cwd#"$proj"/}
  [ "$rel" != "$cwd" ] && proj_section="${proj_section}${GRAY}/${rel}${R}"
fi

# ── 🌿 GIT ───────────────────────────────────────────────────────────
git_section=""
if [ -n "$proj" ] && [ -d "$proj/.git" ]; then
  cd "$proj" 2>/dev/null
  branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null || git rev-parse --short HEAD 2>/dev/null)
  if [ -n "$branch" ]; then
    dirty=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    ab=$(git rev-list --left-right --count "@{u}...HEAD" 2>/dev/null)
    behind=$(printf '%s' "$ab" | awk '{print $1}')
    ahead=$(printf '%s' "$ab" | awk '{print $2}')

    if [ "$dirty" -gt 0 ]; then icon_color="$YELLOW"; else icon_color="$GREEN"; fi
    git_section="${icon_color}🌿 ${branch}${R}"
    [ -n "$ahead" ] && [ "$ahead" -gt 0 ] && git_section+=" ${CYAN}↑${ahead}${R}"
    [ -n "$behind" ] && [ "$behind" -gt 0 ] && git_section+=" ${RED}↓${behind}${R}"
    [ "$dirty" -gt 0 ] && git_section+=" ${YELLOW}●${dirty}${R}${DIM} unsaved${R}"
  fi
fi

# ── ✓ AUTHOR EMAIL (Vercel Hobby gate) ───────────────────────────────
author_section=""
if [ -n "$proj" ] && [ -d "$proj/.git" ]; then
  cd "$proj" 2>/dev/null
  email=$(git config user.email 2>/dev/null)
  if [ -z "$email" ]; then
    author_section="${RED}✗ no git email${R}"
  elif [ "$email" = "ahmed0montaser@gmail.com" ]; then
    author_section="${GREEN}✓ @ahmad${R}"
  else
    short=${email%%@*}
    author_section="${RED}⚠ @${short} (wrong for Vercel)${R}"
  fi
fi

# ── 🤖 MODEL ─────────────────────────────────────────────────────────
case "$mid" in
  *opus*)   short="Opus";   mcolor="$ORANGE" ;;
  *sonnet*) short="Sonnet"; mcolor="$BLUE" ;;
  *haiku*)  short="Haiku";  mcolor="$GREEN" ;;
  *)        short="${mname:-?}"; mcolor="$CYAN" ;;
esac
v=$(printf '%s' "$mid" | grep -oE '[0-9]+-[0-9]+' | head -1 | tr '-' '.')
[ -n "$v" ] && short="$short $v"
[[ "$mid" == *"1m"* ]] && short+=" 1M"
model_section="${mcolor}🤖 ${short}${R}"

# ── 🧠 CONTEXT %  (estimate from transcript size) ────────────────────
ctx_section=""
if [ -n "$transcript" ] && [ -f "$transcript" ]; then
  bytes=$(stat -c%s "$transcript" 2>/dev/null || stat -f%z "$transcript" 2>/dev/null || echo 0)
  # rough: transcript JSONL ~3.2 bytes per token for English (escaped JSON inflates)
  est_tokens=$((bytes / 3))
  # Max context — 1M if model id contains [1m], else 200K (default for Opus/Sonnet/Haiku)
  if [[ "$mid" == *"1m"* ]]; then
    max_ctx=1000000
  else
    max_ctx=200000
  fi
  pct=$((est_tokens * 100 / max_ctx))
  [ "$pct" -gt 100 ] && pct=100

  # Color: green ≤50, yellow ≤80, red beyond (auto-compact triggers ~85)
  if [ "$pct" -ge 80 ]; then ctx_color="$RED"
  elif [ "$pct" -ge 50 ]; then ctx_color="$YELLOW"
  else ctx_color="$GREEN"; fi

  # Format tokens: 145K, 1.2M etc
  if [ "$est_tokens" -ge 1000000 ]; then
    tok_str=$(awk "BEGIN {printf \"%.1fM\", $est_tokens/1000000}")
  elif [ "$est_tokens" -ge 1000 ]; then
    tok_str=$((est_tokens / 1000))K
  else
    tok_str="${est_tokens}"
  fi

  ctx_section="${ctx_color}🧠 ${pct}%${R}${DIM} ${tok_str}${R}"

  # ⚑ HANDOFF — at ≥60% used (=40% remaining): flush handoff.md + /clear (see handoff.sh)
  if [ "$pct" -ge 60 ]; then
    ctx_section="${ctx_section} ${RED}${BOLD}⚑HANDOFF${R}"
  fi
fi

# ── ⚙️ BACKGROUND AGENTS (in-flight Agent tool calls) ─────────────────
bg_section=""
if [ -n "$transcript" ] && [ -f "$transcript" ]; then
  # JSONL lines may contain Agent tool_use (dispatched) and tool_result (completed).
  # In-flight = dispatched IDs minus completed IDs.
  # Cap scan at last 2000 lines to stay fast on long sessions.
  agents_running=$(tail -n 2000 "$transcript" 2>/dev/null | jq -r '
    if (.message.content | type) == "array" then
      .message.content[]
      | if .type == "tool_use" and .name == "Agent" then "DISPATCH " + .id
        elif .type == "tool_result" then "DONE " + .tool_use_id
        else empty end
    else empty end
  ' 2>/dev/null | awk '
    /^DISPATCH / {pending[$2]=1}
    /^DONE / {delete pending[$2]}
    END {print length(pending)}
  ')

  if [ -n "$agents_running" ] && [ "$agents_running" -gt 0 ]; then
    if [ "$agents_running" -ge 3 ]; then bg_color="$RED"
    elif [ "$agents_running" -ge 2 ]; then bg_color="$YELLOW"
    else bg_color="$CYAN"; fi
    bg_section="${bg_color}⚙️  ${agents_running} bg${R}"
  fi
fi

# ── 💰 COST ──────────────────────────────────────────────────────────
if awk "BEGIN {exit !($cost < 0.01)}"; then
  cstr=$(printf '$%.3f' "$cost")
else
  cstr=$(printf '$%.2f' "$cost")
fi
if awk "BEGIN {exit !($cost > 5)}"; then
  ccolor="$RED"
elif awk "BEGIN {exit !($cost > 1)}"; then
  ccolor="$YELLOW"
else
  ccolor="$GREEN"
fi
cost_section="${ccolor}💰 ${cstr}${R}${DIM} session${R}"

# ── 🔋 BATTERY ───────────────────────────────────────────────────────
bat_section=""
if command -v pmset >/dev/null 2>&1; then
  info=$(pmset -g batt 2>/dev/null | grep -Eo '[0-9]+%; [^;]+' | head -1)
  if [ -n "$info" ]; then
    pct=$(printf '%s' "$info" | grep -oE '^[0-9]+')
    state=$(printf '%s' "$info" | grep -oE '; [a-z]+' | tr -d '; ')
    case "$state" in
      charging|charged|finishing|AC) icon="⚡"; bcolor="$GREEN" ;;
      *)
        icon="🔋"
        if [ "$pct" -lt 20 ]; then bcolor="$RED"
        elif [ "$pct" -lt 50 ]; then bcolor="$YELLOW"
        else bcolor="$GREEN"; fi
        ;;
    esac
    bat_section="${bcolor}${icon} ${pct}%${R}"
  fi
fi

# ── 🕐 TIME (12-hour AM/PM, fresh at every render) ───────────────────
time_str=$(date "+%-I:%M %p")
time_section="${GRAY}🕐 ${time_str}${R}"

# ── ASSEMBLE ─────────────────────────────────────────────────────────
out=""
for s in "$proj_section" "$git_section" "$author_section" "$model_section" "$ctx_section" "$bg_section" "$cost_section" "$bat_section" "$time_section"; do
  [ -z "$s" ] && continue
  if [ -z "$out" ]; then out="$s"
  else out="${out}${SEP}${s}"; fi
done

printf "%s" "$out"
