#!/usr/bin/env bash
# ============================================================
# acceptance-feedback.sh — close the loop (feature #1, learning half).
#
# The OS opens PRs/issues but never learns what Ahmad DID with them. This reads the
# dream-ledger, checks each proposed issue/PR's outcome via `gh`, and:
#   • merged / closed-completed  -> a WIN (counts toward precision)
#   • closed-not-planned (wontfix)-> AUTO-SUPPRESS (append to findings-suppressions.json
#                                    so the OS stops re-surfacing it)
#   • open & stale (> STALE_DAYS) -> a nudge
# Then writes a precision metric to the bus so "is the OS getting smarter?" is a number.
#
# Usage:
#   ops/acceptance-feedback.sh [--notify]   DRY_RUN=1 to compute without writing
#
# Fail-open: no ledger / no gh -> status note, exit 0. bash 3.2-safe.
# ============================================================
set -uo pipefail
cd "$(dirname "$0")" || exit 1
. ./lib/os-state.sh 2>/dev/null || true

DRY_RUN="${DRY_RUN:-0}"
NOTIFY=0
for a in "$@"; do [ "$a" = "--notify" ] && NOTIFY=1; done

STATE_DIR="${WHISKY_STATE_DIR:-$HOME/.whisky-os-state}"; mkdir -p "$STATE_DIR"
LEDGER="$STATE_DIR/dream-ledger.json"
SUPPRESSIONS="$STATE_DIR/findings-suppressions.json"
METRIC="$STATE_DIR/acceptance-metrics.json"
STALE_DAYS="${ACCEPTANCE_STALE_DAYS:-21}"

_info(){ printf '%s\n' "$*"; }

if [ ! -f "$LEDGER" ]; then
  _info "[acceptance] no dream-ledger yet — nothing to learn from."
  command -v write_status >/dev/null 2>&1 && write_status "acceptance-feedback" "true" "no ledger yet" '{}'
  exit 0
fi

HAVE_GH=0
command -v gh >/dev/null 2>&1 && HAVE_GH=1

# Collect issue/PR outcomes via gh (one query per unique URL). Pure python builds the
# work-list + applies results; the shell drives gh (so we can skip cleanly if absent).
WORK="$(python3 - "$LEDGER" << 'PY'
import json, sys, re
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print(""); sys.exit(0)
entries = d.get("entries") if isinstance(d, dict) else (d if isinstance(d, list) else [])
seen = set()
for e in entries or []:
    url = (e.get("issue_url") or e.get("pr_url") or "").strip()
    m = re.search(r"https://github\.com/[^\s)]+/(issues|pull)/\d+", url or "")
    if not m or m.group(0) in seen:
        continue
    seen.add(m.group(0))
    print(m.group(0))
PY
)"

TOTAL=0; MERGED=0; WONTFIX=0; OPEN_STALE=0; OPEN_FRESH=0
NEW_SUPP="$(mktemp)"; : > "$NEW_SUPP"

if [ "$HAVE_GH" = "1" ] && [ -n "$WORK" ]; then
  while IFS= read -r url; do
    [ -n "$url" ] || continue
    TOTAL=$((TOTAL+1))
    kind="issue"; printf '%s' "$url" | grep -q '/pull/' && kind="pr"
    # state + reason + updatedAt + the repo/title for suppression keys
    meta="$(gh "$kind" view "$url" --json state,stateReason,updatedAt,title 2>/dev/null || true)"
    [ -n "$meta" ] || { OPEN_FRESH=$((OPEN_FRESH+1)); continue; }
    verdict="$(STALE_DAYS="$STALE_DAYS" python3 - "$meta" << 'PY'
import json, sys, os, datetime
try:
    m = json.loads(sys.argv[1])
except Exception:
    print("skip"); sys.exit(0)
state = (m.get("state") or "").upper()
reason = (m.get("stateReason") or "").upper()
if state in ("MERGED",) or (state == "CLOSED" and reason in ("COMPLETED", "")):
    print("merged");
elif state == "CLOSED" and reason in ("NOT_PLANNED", "NOTPLANNED"):
    print("wontfix")
elif state == "OPEN":
    upd = m.get("updatedAt") or ""
    try:
        dt = datetime.datetime.fromisoformat(upd.replace("Z", "+00:00"))
        age = (datetime.datetime.now(datetime.timezone.utc) - dt).days
    except Exception:
        age = 0
    print("open_stale" if age > int(os.environ.get("STALE_DAYS", "21")) else "open_fresh")
else:
    print("skip")
PY
)"
    case "$verdict" in
      merged) MERGED=$((MERGED+1)) ;;
      wontfix)
        WONTFIX=$((WONTFIX+1))
        # record a suppression key {repo,class,title} from the ledger entry for this url
        printf '%s\n' "$url" >> "$NEW_SUPP" ;;
      open_stale) OPEN_STALE=$((OPEN_STALE+1)) ;;
      *) OPEN_FRESH=$((OPEN_FRESH+1)) ;;
    esac
  done <<EOF
$WORK
EOF
fi

# Build suppression entries for the wontfix URLs by matching them back to ledger entries.
ADDED_SUPP=0
if [ -s "$NEW_SUPP" ] && [ "$DRY_RUN" != "1" ]; then
  ADDED_SUPP="$(python3 - "$LEDGER" "$SUPPRESSIONS" "$NEW_SUPP" << 'PY'
import json, sys, re
ledger_p, supp_p, urls_p = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    d = json.load(open(ledger_p))
    entries = d.get("entries") if isinstance(d, dict) else d
except Exception:
    print(0); sys.exit(0)
wont_urls = set(l.strip() for l in open(urls_p) if l.strip())
def url_of(e):
    u = (e.get("issue_url") or e.get("pr_url") or "")
    m = re.search(r"https://github\.com/[^\s)]+/(issues|pull)/\d+", u or "")
    return m.group(0) if m else None
want = []
for e in entries or []:
    if url_of(e) in wont_urls:
        want.append({"repo": e.get("repo",""), "class": e.get("class",""), "title": e.get("title","")})
# merge into existing suppressions (list of {repo,class,title})
try:
    existing = json.load(open(supp_p))
    existing = existing if isinstance(existing, list) else existing.get("suppress", [])
except Exception:
    existing = []
seen = {(x.get("repo"), x.get("class"), x.get("title")) for x in existing if isinstance(x, dict)}
added = 0
for w in want:
    k = (w["repo"], w["class"], w["title"])
    if k not in seen:
        existing.append(w); seen.add(k); added += 1
json.dump(existing, open(supp_p, "w"), indent=2, ensure_ascii=False)
print(added)
PY
)"
fi
rm -f "$NEW_SUPP"

# precision = wins / decided(wins+wontfix); null until there's signal
PRECISION="$(python3 -c "
w=$MERGED; wf=$WONTFIX
dec=w+wf
print('%.2f' % (w/dec) if dec else 'null')
" 2>/dev/null || echo "null")"

_info ""
_info "=============================================================="
_info "  ACCEPTANCE FEEDBACK"
_info "=============================================================="
if [ "$HAVE_GH" = "1" ]; then
  _info "  proposals checked: $TOTAL"
  _info "  merged/accepted:   $MERGED"
  _info "  wontfix (suppressed +$ADDED_SUPP): $WONTFIX"
  _info "  open (stale>${STALE_DAYS}d / fresh): $OPEN_STALE / $OPEN_FRESH"
  _info "  precision (accepted / decided): $PRECISION"
else
  _info "  gh CLI not available — cannot check outcomes. (install + auth gh to enable)"
fi
_info ""

if [ "$DRY_RUN" != "1" ]; then
  TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  python3 - "$METRIC" "$TS" "$TOTAL" "$MERGED" "$WONTFIX" "$OPEN_STALE" "$OPEN_FRESH" "$PRECISION" "$ADDED_SUPP" << 'PY'
import json, sys, os
metric, ts, total, merged, wontfix, stale, fresh, prec, added = sys.argv[1:10]
try:
    hist = json.load(open(metric)).get("history", []) if os.path.isfile(metric) else []
except Exception:
    hist = []
hist.append({"ts": ts, "checked": int(total), "merged": int(merged), "wontfix": int(wontfix),
             "open_stale": int(stale), "open_fresh": int(fresh),
             "precision": (None if prec == "null" else float(prec)), "suppressed_added": int(added)})
json.dump({"updated_at": ts, "latest": hist[-1], "history": hist[-52:]}, open(metric, "w"), indent=2)
PY
  if command -v write_status >/dev/null 2>&1; then
    ok="true"; [ "$OPEN_STALE" -gt 0 ] && ok="warn"
    write_status "acceptance-feedback" "$ok" \
      "precision=$PRECISION ($MERGED accepted / $WONTFIX wontfix), +$ADDED_SUPP auto-suppressed, $OPEN_STALE stale" \
      "{\"precision\":\"$PRECISION\",\"merged\":$MERGED,\"wontfix\":$WONTFIX,\"stale\":$OPEN_STALE,\"suppressed_added\":$ADDED_SUPP}"
  fi
  command -v emit_event >/dev/null 2>&1 && emit_event "acceptance-feedback" "low" \
    "acceptance: precision=$PRECISION, +$ADDED_SUPP auto-suppressed, $OPEN_STALE stale proposals" \
    "{\"precision\":\"$PRECISION\",\"suppressed_added\":$ADDED_SUPP}"
  if [ "$NOTIFY" = "1" ] && [ -x ./notify.sh ] && { [ "$ADDED_SUPP" -gt 0 ] || [ "$OPEN_STALE" -gt 0 ]; }; then
    ./notify.sh "🧠 acceptance: precision=$PRECISION · +$ADDED_SUPP auto-suppressed · $OPEN_STALE stale proposals to triage." 2>/dev/null || true
  fi
fi
exit 0
