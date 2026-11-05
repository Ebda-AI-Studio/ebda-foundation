#!/usr/bin/env bash
# ============================================================
# Whisky AI OS — mine-video-source.sh
#
# Turns new posts from a creator Ahmad follows into AUDIT RULE candidates.
# Called by ops/audit-pack-daily.sh; usable alone for one profile.
#
#   ops/lib/mine-video-source.sh <profile-url> <max> <seen-file> <out-tsv>
#
# Prints one line per decision and appends `source<TAB>class<TAB>title` for each
# rule found to <out-tsv>. Exit 0 always: a source that cannot be read is a
# SKIPPED line, never a crashed cycle.
#
# THREE THINGS LEARNED THE EXPENSIVE WAY (2026-09-23), all encoded here:
#
#  1. NEVER SEND THE VIDEO. One 2.5-minute reel measured 28,626,271 tokens and
#     exhausted the Gemini key's free tier (250,000 input tokens/day) in a
#     single call. The AUDIO track of the same reel is 687 KB against 37 MB —
#     roughly 5k tokens, so ~50 videos fit in the same daily budget. The caption
#     carries the rest of the signal.
#
#  2. COOKIES ARE SCOPED AND SHREDDED. `yt-dlp --cookies` writes the WHOLE
#     Chrome jar: 2,746 cookies for Google, GitHub, Stripe, Adobe, banking —
#     every site the browser has ever seen. This filters to instagram.com
#     lines, chmod 600, and shreds the full export immediately, with a trap so
#     it happens even on failure.
#
#  3. AN HONEST "NO". Most videos teach no testable rule. The model is told to
#     answer audit_relevant=false with an empty list, and this script reports
#     that as a normal outcome. A pipeline that must produce a lens every day
#     will invent one.
# ============================================================
set -u

PROFILE="${1:?profile url}"
MAX="${2:-3}"
SEEN="${3:-$HOME/.whisky-os-state/audit-pack-seen-posts.txt}"
OUT="${4:-/dev/null}"
LIB="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"; FULL_JAR=""; IG_JAR="$WORK/ig.txt"
DRY_RUN="${DRY_RUN:-0}"

cleanup() {
  [ -n "$FULL_JAR" ] && [ -f "$FULL_JAR" ] && { shred -u "$FULL_JAR" 2>/dev/null || rm -f "$FULL_JAR"; }
  rm -rf "$WORK"
}
trap cleanup EXIT

_say() { echo "$*"; }
touch "$SEEN" 2>/dev/null || true

# ── 1. cookies: instagram only ──────────────────────────────────────────────
command -v yt-dlp >/dev/null 2>&1 || { _say "  skipped: video (yt-dlp not installed)"; exit 0; }
# The STORED jar first. Chrome locks its cookie database while it runs, so a live export at
# 09:00 returns 407 of 2,746 cookies WITHOUT sessionid — the job would fail every working day.
STORED="${IG_SESSION_FILE:-$HOME/.whisky-os-state/ig-session-cookies.txt}"
if [ -s "$STORED" ] && grep -q sessionid "$STORED" 2>/dev/null; then
  cp "$STORED" "$IG_JAR"; chmod 600 "$IG_JAR"
else
  FULL_JAR="$WORK/full.txt"
  yt-dlp --cookies-from-browser chrome --cookies "$FULL_JAR" --skip-download \
    "https://www.instagram.com/reel/DdZDAYDkr3A/" >/dev/null 2>&1 || true
  if [ ! -s "$FULL_JAR" ]; then
    _say "  skipped: video (no session — quit Chrome once and run ops/lib/refresh-ig-session.sh)"
    exit 0
  fi
  { echo "# Netscape HTTP Cookie File"
    awk -F'\t' '/instagram\.com/{sub(/^#HttpOnly_/,""); print}' "$FULL_JAR"; } > "$IG_JAR"
  chmod 600 "$IG_JAR"
  shred -u "$FULL_JAR" 2>/dev/null || rm -f "$FULL_JAR"; FULL_JAR=""
  if ! grep -q sessionid "$IG_JAR" 2>/dev/null; then
    _say "  skipped: video (no session cookie — quit Chrome once and run ops/lib/refresh-ig-session.sh)"
    exit 0
  fi
fi

# ── 2. discovery: the profile, through a logged-in browser ──────────────────
command -v node >/dev/null 2>&1 || { _say "  skipped: video (node missing)"; exit 0; }
listing="$(node "$LIB/ig-list.mjs" "$PROFILE" "$IG_JAR" 2>&1)"; list_rc=$?
# Three different failures, three different sentences. They were one message before, and a
# missing node module read as "your session expired".
if [ "$list_rc" -eq 3 ] || printf '%s' "$listing" | grep -q "listing failed"; then
  _say "  skipped: video ($(printf '%s' "$listing" | grep -m1 'listing failed' | cut -c1-120))"
  exit 0
fi
if [ "$list_rc" -ne 0 ]; then
  _say "  skipped: video (lister exited $list_rc: $(printf '%s' "$listing" | tail -1 | cut -c1-100))"
  exit 0
fi
if ! printf '%s' "$listing" | grep -q "logged in: true"; then
  _say "  skipped: video (session expired — open instagram.com in Chrome and log in again)"
  exit 0
fi
_extract_codes() { printf '%s' "$1" | grep -oE '/(reel|p)/[A-Za-z0-9_-]+' | awk -F/ '{print $3}' | awk '!seen[$0]++'; }
shortcodes="$(_extract_codes "$listing")"
total="$(printf '%s\n' "$shortcodes" | grep -c . || true)"
if [ "$total" -eq 0 ]; then
  # Logged in but an EMPTY grid is Instagram throttling a burst of loads, NOT an empty profile.
  # Reporting it as "nothing new" would hide the throttle forever. One patient retry, then say so.
  sleep 45
  listing="$(node "$LIB/ig-list.mjs" "$PROFILE" "$IG_JAR" 2>&1)" || true
  shortcodes="$(_extract_codes "$listing")"
  total="$(printf '%s\n' "$shortcodes" | grep -c . || true)"
  [ "$total" -eq 0 ] && { _say "  skipped: video (logged in, but the profile returned no posts — Instagram is throttling; it will retry tomorrow)"; exit 0; }
fi
_say "  video: $total posts on the profile"

# ── 3. the new ones only, capped ────────────────────────────────────────────
n=0
for code in $shortcodes; do
  [ -n "$code" ] || continue
  grep -qxF "$code" "$SEEN" 2>/dev/null && continue
  if [ "$n" -ge "$MAX" ]; then _say "  video: cap $MAX/run reached — the rest wait for tomorrow"; break; fi
  n=$((n+1))
  if [ "$DRY_RUN" = "1" ]; then _say "  DRY_RUN: would watch $code"; continue; fi

  ( cd "$WORK" && yt-dlp --cookies "$IG_JAR" --write-description --quiet --no-warnings \
      -o "%(id)s.%(ext)s" "https://www.instagram.com/reel/$code/" >/dev/null 2>&1 ) || {
    _say "  skipped: $code (download failed)"; echo "$code" >> "$SEEN"; continue; }
  local_mp4="$(find "$WORK" -maxdepth 1 -name "*.mp4" | head -1)"
  [ -n "$local_mp4" ] || { _say "  skipped: $code (no video file)"; echo "$code" >> "$SEEN"; continue; }

  # AUDIO ONLY — see the header. 37 MB of video becomes ~700 KB of audio.
  audio="$WORK/$code.m4a"
  if command -v ffmpeg >/dev/null 2>&1; then
    ffmpeg -y -i "$local_mp4" -vn -ac 1 -ar 16000 -b:a 32k "$audio" -loglevel error >/dev/null 2>&1
  fi
  [ -s "$audio" ] || { _say "  skipped: $code (could not extract audio)"; rm -f "$local_mp4"; echo "$code" >> "$SEEN"; continue; }
  caption="$(cat "$WORK"/*.description 2>/dev/null | head -c 1500)"

  if [ -z "${GEMINI_API_KEY:-}" ]; then
    _say "  skipped: $code (GEMINI_API_KEY not set — cannot watch)"; rm -f "$local_mp4" "$audio"; continue
  fi
  size="$(stat -c%s "$audio" 2>/dev/null || stat -f%z "$audio")"
  up="$(curl -s -X POST "https://generativelanguage.googleapis.com/upload/v1beta/files?key=$GEMINI_API_KEY" \
        -H "X-Goog-Upload-Command: start, upload, finalize" \
        -H "X-Goog-Upload-Header-Content-Length: $size" \
        -H "X-Goog-Upload-Header-Content-Type: audio/mp4" \
        -H "Content-Type: application/json" --data-binary @"$audio" --max-time 300)"
  uri="$(printf '%s' "$up" | python3 -c "import json,sys;print((json.load(sys.stdin).get('file') or {}).get('uri',''))" 2>/dev/null)"
  [ -n "$uri" ] || { _say "  skipped: $code (audio upload failed)"; rm -f "$local_mp4" "$audio"; continue; }

  req="$WORK/req.json"
  python3 - "$uri" "$caption" > "$req" <<'PY'
import json,sys
uri, caption = sys.argv[1], sys.argv[2][:1500]
prompt = (
 "You are mining this video's AUDIO and its caption for AUDIT RULES: checks a static analyser could "
 "run against a web codebase, or a probe could run against a live site.\n\nCAPTION:\n" + caption +
 "\n\nReturn ONLY JSON: {\"summary\":\"<=25 words\",\"audit_relevant\":true|false,"
 "\"rules\":[{\"id\":\"kebab-case-id\",\"title\":\"<=8 words\",\"rule\":\"one sentence a probe could test\","
 "\"why\":\"what breaks if ignored\",\"probe_hint\":\"what a script would grep or request\","
 "\"severity\":\"critical|high|medium|low\"}],\"market_signal\":\"one sentence if this is industry or strategy "
 "commentary rather than a testable rule, else empty\"}\n\n"
 "Most videos teach NO testable rule. If this one does not, set audit_relevant=false and rules=[]. "
 "Never invent a rule to fill the list.")
json.dump({"contents":[{"parts":[{"file_data":{"mime_type":"audio/mp4","file_uri":uri}},{"text":prompt}]}],
           "generationConfig":{"temperature":0.2,"responseMimeType":"application/json"}}, sys.stdout)
PY
  # flash-LITE per the routing rule (bulk mechanical NLP), and one retry: the first live run met
  # "This model is currently experiencing high demand", which is transient.
  out="$WORK/out.json"
  for attempt in 1 2; do
    curl -s -X POST "https://generativelanguage.googleapis.com/v1beta/models/gemini-flash-lite-latest:generateContent?key=$GEMINI_API_KEY" \
      -H 'Content-Type: application/json' -d @"$req" --max-time 600 -o "$out"
    grep -q '"error"' "$out" 2>/dev/null || break
    [ "$attempt" = "1" ] && sleep 20
  done
  verdict="$(python3 - "$out" "$code" "$OUT" <<'PY'
import json,sys
path, code, out_tsv = sys.argv[1], sys.argv[2], sys.argv[3]
try: d=json.load(open(path))
except Exception: print("unreadable response"); sys.exit(0)
if "error" in d:
    msg=(d["error"].get("message") or "")[:90]
    print(f"gemini error: {msg}"); sys.exit(0)
try:
    r=json.loads(d["candidates"][0]["content"]["parts"][0]["text"])
except Exception:
    print("could not parse the model's JSON"); sys.exit(0)
rules=r.get("rules") or []
if not r.get("audit_relevant") or not rules:
    sig=(r.get("market_signal") or r.get("summary") or "")[:110]
    print(f"no rule (market signal: {sig})"); sys.exit(0)
with open(out_tsv,"a") as f:
    for x in rules:
        rid=(x.get("id") or x.get("title","rule")).strip().lower().replace(" ","-")
        f.write(f"video-matt-murphy\t{rid}\t{x.get('rule','')[:160]}\n")
print(f"{len(rules)} rule(s): " + ", ".join((x.get('id') or x.get('title','?')) for x in rules))
PY
)"
  _say "  watched $code → $verdict"
  # SEEN only on a real verdict. Marking a post seen after a transient model error burns it:
  # it would never be watched again, and the rule it teaches would be lost silently.
  case "$verdict" in
    "gemini error:"*|"unreadable response"|"could not parse"*) _say "  → $code stays unseen; it will be retried tomorrow" ;;
    *) echo "$code" >> "$SEEN" ;;
  esac
  rm -f "$local_mp4" "$audio" "$WORK"/*.description 2>/dev/null || true
done
[ "$n" -eq 0 ] && _say "  video: nothing new since the last run"
exit 0
