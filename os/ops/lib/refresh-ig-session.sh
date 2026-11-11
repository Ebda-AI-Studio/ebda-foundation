#!/usr/bin/env bash
# ============================================================
# Whisky AI OS — refresh-ig-session.sh
#
# Stores an INSTAGRAM-ONLY cookie jar for the daily audit-pack cycle.
#
#   ops/lib/refresh-ig-session.sh          # quit Chrome first
#
# WHY THIS EXISTS. Chrome holds a lock on its cookie database while it runs:
# with Chrome open, `yt-dlp --cookies-from-browser chrome` returns 407 of 2,746
# cookies and `sessionid` is NOT among them — so the 09:00 job would fail every
# day while Ahmad is working. Quit Chrome once, run this, and the job reads the
# stored jar instead of the browser.
#
# WHAT IT REFUSES TO DO. yt-dlp's export is the WHOLE browser: Google, GitHub,
# Stripe, Adobe, banking — 2,746 cookies. That file never survives this script:
# it is written with 600 perms, filtered to instagram.com, and shredded.
# ============================================================
set -u
OUT="${IG_SESSION_FILE:-$HOME/.whisky-os-state/ig-session-cookies.txt}"
W="$(mktemp -d)"; FULL="$W/full.txt"
trap '[ -f "$FULL" ] && { shred -u "$FULL" 2>/dev/null || rm -f "$FULL"; }; rm -rf "$W"' EXIT

if pgrep -x "Google Chrome" >/dev/null 2>&1; then
  echo "Chrome is running — it locks the cookie database and the session cookie will be missing."
  echo "Quit Chrome, then run this again."
  exit 1
fi
mkdir -p "$(dirname "$OUT")"
umask 077
yt-dlp --cookies-from-browser chrome --cookies "$FULL" --skip-download \
  "https://www.instagram.com/reel/DdZDAYDkr3A/" >/dev/null 2>&1 || true
[ -s "$FULL" ] || { echo "no cookies could be read from Chrome"; exit 1; }
{ echo "# Netscape HTTP Cookie File"
  awk -F'\t' '/instagram\.com/{sub(/^#HttpOnly_/,""); print}' "$FULL"; } > "$OUT"
chmod 600 "$OUT"
names="$(awk -F'\t' '{print $6}' "$OUT" | tr '\n' ' ')"
echo "stored $(grep -c instagram "$OUT") instagram cookies in $OUT (600)"
echo "names: $names"
case "$names" in
  *sessionid*) echo "session cookie present — the daily cycle can read the profile" ;;
  *) echo "WARNING: no sessionid — log in to instagram.com in Chrome, quit it, and run this again"; exit 1 ;;
esac
