#!/usr/bin/env bash
# ============================================================
# Whisky AI OS — audit-pack-daily.sh   (the audit pack's own dreaming cycle)
#
# PURPOSE: keep the mypovonai audit pack GROWING and HONEST, every day.
#
# PHASES:
#   A. DRIFT   — does the site's claim match the published package? On 2026-09-23
#                mypovonai.com sold "37 lenses over your source" while npm shipped
#                31: six lenses merged months apart were never released. Nothing
#                was watching the gap between the claim and the artifact.
#   B. MINE    — read the day's sources (ops/lib/audit-sources.json) and turn each
#                new finding CLASS into a lens candidate. The OS watchdog is a
#                source by itself: what it catches in our repos is what the audit
#                should catch in a client's.
#   C. PROPOSE — one GitHub issue per new candidate, carrying the criterion, a
#                probe sketch, and the fixture pair it needs. PROPOSE ONLY: a lens
#                reaches the product through a reviewed PR with all four files.
#   D. REPORT  — one Telegram line through ops/notify.sh.
#
# Usage:
#   ops/audit-pack-daily.sh                  # all phases, quiet
#   ops/audit-pack-daily.sh --notify         # + Telegram when something changed
#   ops/audit-pack-daily.sh --notify --always
#   ops/audit-pack-daily.sh --phase drift|mine|propose|report
#   DRY_RUN=1 ops/audit-pack-daily.sh        # measure and print; file nothing
#
# Environment:
#   DRY_RUN=1                  no issues filed, no state written
#   AUDIT_PACK_MAX_PROPOSALS   issues per run (default 2)
#   AUDIT_PACK_STATE           state dir (default ~/.whisky-os-state)
#   AUDIT_PACK_FLEET           fleet dir (default $OS_PROJECTS_DIR/Personal/projects/mypovonai-learn/fleet)
#   AUDIT_PACK_LENS_IDS        comma list, overrides reading the fleet (tests)
#   AUDIT_PACK_FAKE_REPO/_NPM/_SITE   seeded counts (tests)
#
# FAIL OPEN, REPORT LOUDLY: no network, no gh, missing file → that phase prints
# `skipped: <what> (<why>)` and the run continues. A phase that could not measure
# NEVER prints `aligned` — silence is not evidence.
# ============================================================
# shellcheck source=lib/os-config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/os-config.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-config.sh" 2>/dev/null || true
command -v os_config_load >/dev/null 2>&1 && os_config_load
set -u

STATE_DIR="${AUDIT_PACK_STATE:-$HOME/.whisky-os-state}"
FLEET="${AUDIT_PACK_FLEET:-$OS_PROJECTS_DIR/Personal/projects/mypovonai-learn/fleet}"
LIBDIR="$(cd "$(dirname "$0")" && pwd)/lib"
# Overridable so a test can mine a SEEDED source list offline. Without this
# seam the only way to exercise a miner is to edit the real config or hit the
# network, and a miner nobody can test is one that fails quietly.
SOURCES="${AUDIT_PACK_SOURCES:-$(cd "$(dirname "$0")" && pwd)/lib/audit-sources.json}"
STATUS="$STATE_DIR/audit-pack-status.json"
REPO_SLUG="$OS_PERSONAL_OWNER/mypovonai-learn"
SITE_URL="https://mypovonai.com/en/audit"
MAX_PROPOSALS="${AUDIT_PACK_MAX_PROPOSALS:-2}"
DRY_RUN="${DRY_RUN:-0}"
PHASE="all"; NOTIFY=0; ALWAYS=0

while [ $# -gt 0 ]; do
  case "$1" in
    --phase) PHASE="${2:-all}"; shift 2 ;;
    --notify) NOTIFY=1; shift ;;
    --always) ALWAYS=1; shift ;;
    *) shift ;;
  esac
done

mkdir -p "$STATE_DIR" 2>/dev/null || true
_say() { echo "$*"; }
DEAD_SOURCES=""

# ── A. DRIFT ────────────────────────────────────────────────────────────────
repo_lenses=""; npm_lenses=""; npm_version=""; site_lenses=""; drift_line=""

phase_drift() {
  # repo
  if [ -n "${AUDIT_PACK_FAKE_REPO+x}" ]; then repo_lenses="$AUDIT_PACK_FAKE_REPO"
  elif [ -d "$FLEET/lenses" ]; then repo_lenses="$(find "$FLEET/lenses" -maxdepth 1 -name '*.json' | wc -l | tr -d ' ')"
  else _say "  skipped: repo (no fleet at $FLEET/lenses)"; fi

  # npm — the PUBLISHED tarball, not the repo's package.json: what a buyer installs
  if [ -n "${AUDIT_PACK_FAKE_NPM:-}" ]; then npm_lenses="$AUDIT_PACK_FAKE_NPM"; npm_version="${AUDIT_PACK_FAKE_NPM_VERSION:-fake}"
  elif [ -n "${AUDIT_PACK_FAKE_NPM+x}" ]; then _say "  skipped: npm (seeded as unmeasured)"
  else
    local tmp; tmp="$(mktemp -d)"
    if ( cd "$tmp" && npm pack mypovonai-audit@latest >/dev/null 2>&1 && tar -xzf ./*.tgz >/dev/null 2>&1 ); then
      npm_lenses="$(find "$tmp/package/lenses" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l | tr -d ' ')"
      npm_version="$(node -p "require('$tmp/package/package.json').version" 2>/dev/null || echo '?')"
    else
      _say "  skipped: npm (could not fetch the published tarball)"
    fi
    rm -rf "$tmp"
  fi

  # site — the rendered claim
  if [ -n "${AUDIT_PACK_FAKE_SITE+x}" ]; then site_lenses="$AUDIT_PACK_FAKE_SITE"
  else
    local html; html="$(curl -4 -s --max-time 60 "$SITE_URL" 2>/dev/null)"
    if [ -n "$html" ]; then
      site_lenses="$(printf '%s' "$html" | python3 -c "
import sys,re
h=re.sub(r'<[^>]+>','',sys.stdin.read())
m=re.search(r'([0-9]+)\s+lenses over your source', h)
print(m.group(1) if m else '')" 2>/dev/null)"
      [ -z "$site_lenses" ] && _say "  skipped: site (no lens count found in the page)"
    else
      _say "  skipped: site (could not fetch $SITE_URL)"
    fi
  fi

  if [ -z "$repo_lenses" ] || [ -z "$npm_lenses" ] || [ -z "$site_lenses" ]; then
    _say "  drift: UNKNOWN — a number could not be measured, so nothing is claimed"
    return 0
  fi
  if [ "$site_lenses" = "$npm_lenses" ] && [ "$repo_lenses" = "$npm_lenses" ]; then
    _say "  aligned: $repo_lenses lenses in the repo, in npm ($npm_version), and on the site"
  else
    drift_line="DRIFT: site says $site_lenses, npm ships $npm_lenses (repo has $repo_lenses)"
    _say "  $drift_line"
    _say "  → a buyer installs fewer checks than the page sells; publish or change the claim"
  fi
}

# ── B. MINE ─────────────────────────────────────────────────────────────────
CANDIDATES_FILE=""

_lens_ids() {
  if [ -n "${AUDIT_PACK_LENS_IDS:-}" ]; then printf '%s' "$AUDIT_PACK_LENS_IDS" | tr ',' '\n'
  elif [ -d "$FLEET/lenses" ]; then find "$FLEET/lenses" -maxdepth 1 -name '*.json' -exec basename {} .json \;
  fi
}

# A class is already covered when its words overlap a lens id or a criterion id.
# Report markdown under a client root. Split out because a `find` inside a
# command substitution inside a heredoc is a parse error waiting to happen.
_client_reports() {
  local r
  while IFS= read -r r; do
    [ -d "$r" ] || continue
    # `-path '*report*'` matched node_modules/next/dist/docs/.../use-report-web-vitals.md
    # and filled the whole list with dependency docs before reaching one real
    # report. A path filter reads the WHOLE path, including directories that
    # belong to the machine rather than to the client's work.
    find "$r" -type d \( -name node_modules -o -name vendor -o -name .git \) -prune -o \
         -type f -name '*.md' -path '*/reports/*' -print 2>/dev/null | head -50
  done <<ROOTS
$1
ROOTS
}

_covered_by() {
  local class="$1" id
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    case "$class" in
      "$id"|"$id"-*|*-"$id") echo "$id"; return 0 ;;
    esac
    # criterion ids inside the manifest
    if [ -f "$FLEET/lenses/$id.json" ] && grep -q "\"$class\"" "$FLEET/lenses/$id.json" 2>/dev/null; then echo "$id"; return 0; fi
  done <<EOF
$(_lens_ids)
EOF
  return 1
}

phase_mine() {
  CANDIDATES_FILE="$(mktemp)"
  [ -f "$SOURCES" ] || { _say "  skipped: sources (no $SOURCES)"; return 0; }
  local n; n="$(python3 -c "import json;print(len(json.load(open('$SOURCES'))['sources']))" 2>/dev/null || echo 0)"
  local i=0
  while [ "$i" -lt "$n" ]; do
    local id kind enabled
    id="$(python3 -c "import json;print(json.load(open('$SOURCES'))['sources'][$i].get('id',''))")"
    kind="$(python3 -c "import json;print(json.load(open('$SOURCES'))['sources'][$i].get('kind',''))")"
    enabled="$(python3 -c "import json;print(json.load(open('$SOURCES'))['sources'][$i].get('enabled',False))")"
    case "$kind" in
      state-file)
        if [ "$enabled" != "True" ]; then _say "  skipped: $id (disabled)"; i=$((i+1)); continue; fi
        local paths found_any=0
        paths="$(python3 -c "import json;print('\n'.join(json.load(open('$SOURCES'))['sources'][$i].get('paths',[])))")"
        while IFS= read -r rel; do
          [ -n "$rel" ] || continue
          local f="$STATE_DIR/$(basename "$rel")"
          if [ ! -s "$f" ]; then _say "  skipped: $id ($(basename "$rel") empty or unreadable)"; continue; fi
          local classes
          classes="$(python3 - "$f" <<'PY' 2>/dev/null
import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: sys.exit(0)
out={}
for f in (d.get("findings") or []):
    c=f.get("class")
    if c and c not in out: out[c]=f.get("title","")
for c,t in out.items(): print(f"{c}\t{t}")
PY
)"
          [ -n "$classes" ] && found_any=1
          while IFS=$'\t' read -r cls title; do
            [ -n "$cls" ] || continue
            local lens
            if lens="$(_covered_by "$cls")"; then
              _say "  covered by lens $lens: $cls"
            else
              _say "  candidate: $cls — $title"
              printf '%s\t%s\t%s\n' "$id" "$cls" "$title" >> "$CANDIDATES_FILE"
            fi
          done <<EOF
$classes
EOF
        done <<EOF
$paths
EOF
        [ "$found_any" -eq 0 ] && _say "  skipped: $id (empty — no findings to learn from)"
        ;;
      instagram)
        local profile maxrun
        profile="$(python3 -c "import json;print(json.load(open('$SOURCES'))['sources'][$i].get('profile',''))")"
        maxrun="$(python3 -c "import json;print(json.load(open('$SOURCES'))['sources'][$i].get('max_per_run',3))")"
        if [ "${AUDIT_PACK_SKIP_VIDEO:-0}" = "1" ]; then
          _say "  skipped: $id (skipped by env — tests stay off the network)"
        elif [ "$enabled" != "True" ] || [ -z "$profile" ]; then
          _say "  skipped: $id (no profile configured)"
        else
          # New posts -> audio -> rules. Never the video itself (28.6M tokens for one reel).
          local vout
          vout="$(bash "${AUDIT_PACK_VIDEO_LIB:-$(cd "$(dirname "$0")" && pwd)/lib/mine-video-source.sh}" \
            "$profile" "$maxrun" "$STATE_DIR/audit-pack-seen-posts.txt" "$CANDIDATES_FILE" 2>&1)"
          printf '%s\n' "$vout" | sed 's/^/ /'
          # An ENABLED source that could not run is a dead control, not a quiet day. It used
          # to print "skipped" and the run still reported "aligned", so the primary source
          # (Murphy) sat dead with no alert (found 2026-10-08). Collect it for the report.
          if printf '%s' "$vout" | grep -q 'skipped: video'; then
            DEAD_SOURCES="${DEAD_SOURCES:+$DEAD_SOURCES, }$id ($(printf '%s' "$vout" | grep -m1 -o 'skipped: video ([^)]*' | sed 's/skipped: video (//' | cut -c1-80))"
          fi
        fi
        ;;
      youtube)
        local channel
        channel="$(python3 -c "import json;print(json.load(open('$SOURCES'))['sources'][$i].get('channel',''))")"
        if [ "$enabled" != "True" ] || [ -z "$channel" ]; then
          _say "  skipped: $id (no channel configured)"
        else
          _say "  source $id: $channel (feed read below)"
          local feed; feed="$(curl -4 -s --max-time 40 "$channel" 2>/dev/null | head -c 200000)"
          if [ -z "$feed" ]; then _say "  skipped: $id (feed unreachable)"; else
            printf '%s' "$feed" | python3 -c "
import sys,re
x=sys.stdin.read()
for t in re.findall(r'<title>([^<]{4,120})</title>', x)[1:6]: print('  video:', t)
" 2>/dev/null
            _say "  → watch these with the video-perception skill and file the rules they teach"
          fi
        fi
        ;;
      release-notes)
        local wd; wd="$(python3 -c "import json;print(json.load(open('$SOURCES'))['sources'][$i].get('weekly_on',0))")"
        if [ "$(date +%w)" != "$wd" ]; then _say "  skipped: $id (weekly, runs on day $wd)"
        elif [ "$enabled" != "True" ]; then _say "  skipped: $id (disabled)"
        else
          local urls; urls="$(python3 -c "import json;print('\n'.join(json.load(open('$SOURCES'))['sources'][$i].get('urls',[])))")"
          while IFS= read -r u; do
            [ -n "$u" ] || continue
            local body; body="$(curl -4 -s --max-time 40 "$u" 2>/dev/null | head -c 120000)"
            if [ -z "$body" ]; then _say "  skipped: $id ($u unreachable)"; continue; fi
            printf '%s' "$body" | python3 -c "
import sys,re
x=sys.stdin.read()
for t in re.findall(r'<title>([^<]{4,140})</title>', x)[1:4]: print('  market:', t.strip())
" 2>/dev/null
          done <<EOF
$urls
EOF
        fi
        ;;
      advisory-feed)
        # Real advisories, so php-deps can pin something VERIFIED instead of the
        # four structural facts it ships with. The advisories are recorded as
        # DATA and only ONE lens candidate is ever proposed from them: filing a
        # lens per CVE would open fifty issues for one idea, which is the noise
        # failure this cycle exists to avoid.
        local urls maxadv advfile seen_total=0 got_body=0
        urls="$(python3 -c "import json;print('\n'.join(json.load(open('$SOURCES'))['sources'][$i].get('urls',[])))")"
        maxadv="$(python3 -c "import json;print(json.load(open('$SOURCES'))['sources'][$i].get('max_per_run',25))")"
        advfile="$STATE_DIR/audit-pack-advisories.tsv"
        if [ "$enabled" != "True" ]; then _say "  skipped: $id (disabled)"
        elif [ -z "$urls" ]; then _say "  skipped: $id (no urls configured)"
        else
          local u body rows ident title
          while IFS= read -r u; do
            [ -n "$u" ] || continue
            if [ -n "${AUDIT_PACK_FAKE_ADVISORIES:-}" ]; then
              # Offline seam. A source that can only be exercised online is a
              # source nobody tests, and an untested miner fails quietly.
              body="$(cat "$AUDIT_PACK_FAKE_ADVISORIES" 2>/dev/null)"
            else
              body="$(curl -4 -s --max-time 40 \
                        -H 'Accept: application/vnd.github+json' \
                        -H 'User-Agent: ebda-os-audit-pack/1.0' \
                        "$u" 2>/dev/null | head -c 400000)"
            fi
            if [ -z "$body" ]; then _say "  skipped: $id ($u unreachable)"; continue; fi
            got_body=1
            rows="$(printf '%s' "$body" | python3 "$LIBDIR/parse-advisories.py" "$maxadv" 2>/dev/null)"
            while IFS="$(printf '\t')" read -r ident title; do
              [ -n "$ident" ] || continue
              seen_total=$((seen_total+1))
              grep -q "^$ident$(printf '\t')" "$advfile" 2>/dev/null && continue
              printf '%s\t%s\t%s\n' "$ident" "$(date +%F)" "$title" >> "$advfile"
              _say "  advisory: $ident ${title:0:70}"
            done <<ADV
$rows
ADV
          done <<ADVURLS
$urls
ADVURLS
          if [ "$got_body" -eq 0 ]; then
            : # every url already said it was unreachable -- one reason is enough
          elif [ "$seen_total" -eq 0 ]; then
            _say "  skipped: $id (feed read but no advisory ids in it — shape changed?)"
          elif lens="$(_covered_by "dep-known-advisory")"; then
            _say "  covered by lens $lens: dep-known-advisory ($seen_total advisory/ies recorded)"
          else
            _say "  candidate: dep-known-advisory — a dependency with a published advisory ($seen_total recorded)"
            printf '%s\t%s\t%s\n' "$id" "dep-known-advisory" "a dependency with a published advisory; $seen_total recorded in $(basename "$advfile")" >> "$CANDIDATES_FILE"
          fi
        fi
        ;;
      client-audit)
        # The highest-yield source measured so far: ONE hand audit of a client
        # Laravel repo produced 11 lenses. A finding a human wrote up is a class
        # the pack should catch by itself next time, and unlike a reel or a feed
        # it is already specific to work Ahmad is paid for.
        local roots maxc reports proposed=0
        roots="$(python3 -c "import glob,json,os;print('\n'.join(g for p in json.load(open('$SOURCES'))['sources'][$i].get('roots',[]) for g in sorted(glob.glob(os.path.expanduser(os.path.expandvars(p))))))")"
        maxc="$(python3 -c "import json;print(json.load(open('$SOURCES'))['sources'][$i].get('max_per_run',5))")"
        if [ "$enabled" != "True" ]; then _say "  skipped: $id (disabled)"
        elif [ -z "$roots" ]; then _say "  skipped: $id (no roots configured)"
        else
          reports="$(_client_reports "$roots")"
          if [ -z "$reports" ]; then
            _say "  skipped: $id (no report markdown under the configured roots)"
          else
            local rows cls title lens
            rows="$(printf '%s\n' "$reports" | python3 "$LIBDIR/parse-client-findings.py" 2>/dev/null)"
            if [ -z "$rows" ]; then
              _say "  skipped: $id (reports found but no '### XXX-nn: title' findings in them)"
            else
              while IFS="$(printf '\t')" read -r cls title; do
                [ -n "$cls" ] || continue
                [ "$proposed" -ge "$maxc" ] && continue
                if lens="$(_covered_by "$cls")"; then
                  _say "  covered by lens $lens: $cls"
                else
                  # A HINT, never a verdict. Word overlap mis-attributed every
                  # time it was trusted to suppress (cicd "covering" a file
                  # upload), and a wrong suppression hides a real gap. So the
                  # candidate is always proposed and the likely owners ride
                  # along for whoever reads the issue.
                  local hint=""
                  hint="$(python3 "$LIBDIR/class-hint.py" "$FLEET" "$cls" 2>/dev/null)"
                  if [ -n "$hint" ]; then
                    _say "  candidate: $cls — $title [check first: $hint]"
                    printf '%s\t%s\t%s\n' "$id" "$cls" "$title — possibly already covered by: $hint" >> "$CANDIDATES_FILE"
                  else
                    _say "  candidate: $cls — $title"
                    printf '%s\t%s\t%s\n' "$id" "$cls" "$title" >> "$CANDIDATES_FILE"
                  fi
                  proposed=$((proposed+1))
                fi
              done <<CLI
$rows
CLI
              [ "$proposed" -eq 0 ] && _say "  $id: every finding class in those reports is already covered"
            fi
          fi
        fi
        ;;
      *) _say "  skipped: $id (unknown kind '$kind')" ;;
    esac
    i=$((i+1))
  done
}

# ── C. PROPOSE ──────────────────────────────────────────────────────────────
filed=0
phase_propose() {
  [ -n "$CANDIDATES_FILE" ] && [ -f "$CANDIDATES_FILE" ] || { phase_mine >/dev/null; }
  [ -s "${CANDIDATES_FILE:-/dev/null}" ] || { _say "  nothing to propose"; return 0; }
  while IFS=$'\t' read -r src cls title; do
    [ -n "$cls" ] || continue
    if [ "$filed" -ge "$MAX_PROPOSALS" ]; then _say "  cap reached ($MAX_PROPOSALS/run) — the rest wait for tomorrow"; break; fi
    local issue_title="lens: $cls"
    if [ "$DRY_RUN" != "1" ] && command -v gh >/dev/null 2>&1; then
      if gh issue list -R "$REPO_SLUG" --state all --search "$issue_title in:title" --json title \
           --jq '.[].title' 2>/dev/null | grep -qxF "$issue_title"; then
        _say "  already proposed: $cls"; continue
      fi
    fi
    local body
    body="$(cat <<BODY
**Source:** \`$src\` · **class:** \`$cls\`

**Seen:** $title

**Proposed criterion** (rubric voice — what a reader should be able to check):
> A project is flagged when it exhibits \`$cls\`. Write the sentence so a stranger can tell
> a real instance from a false one without reading the probe.

**Probe sketch:** which files it reads, what it greps for, and what it calls a finding.
Prefer one precise site over a broad pattern — a naive parser once produced 110 false
positives on a single client repo.

**Fixtures:** a known-bad fixture the probe FIRES on, and a clean twin it stays silent on.

**The bar:** a lens ships only with all four files — rubric entry, probe branch, known-bad
fixture, clean twin — plus a mutation proof (break it → the finding appears; restore → gone).
Proposed automatically by \`ops/audit-pack-daily.sh\`; nothing is merged without review.
BODY
)"
    if [ "$DRY_RUN" = "1" ]; then
      _say "  DRY_RUN: would file issue: $issue_title"
      # Print the BAR line too: a dry run that hides the requirement it is enforcing
      # tells the reader nothing about what the issue would actually demand.
      printf '%s\n' "$body" | grep -E "Proposed criterion|all four files" | sed 's/^/      /'
      filed=$((filed+1)); continue
    fi
    if command -v gh >/dev/null 2>&1; then
      local gh_err gh_rc
      gh_err="$(gh issue create -R "$REPO_SLUG" --title "$issue_title" --body "$body" --label "lens-candidate" 2>&1 >/dev/null)"; gh_rc=$?
      if [ "$gh_rc" -eq 0 ]; then
        _say "  filed: $issue_title"; filed=$((filed+1))
      else
        # gh's OWN words, not a guess: "label missing?" once hid a plain network timeout.
        _say "  skipped: could not file '$issue_title' — $(printf '%s' "$gh_err" | tr '\n' ' ' | cut -c1-160)"
      fi
    else
      _say "  skipped: gh not installed, cannot file '$issue_title'"
    fi
  done < "$CANDIDATES_FILE"
}

# ── D. REPORT ───────────────────────────────────────────────────────────────
phase_report() {
  local cands=0
  [ -s "${CANDIDATES_FILE:-/dev/null}" ] && cands="$(wc -l < "$CANDIDATES_FILE" | tr -d ' ')"
  local line="audit pack — ${drift_line:-aligned: ${repo_lenses:-?} lenses} · candidates: $cands · filed: $filed"
  [ -n "${DEAD_SOURCES:-}" ] && line="$line · DEAD SOURCE: $DEAD_SOURCES"
  _say "  $line"
  if [ "$DRY_RUN" != "1" ]; then
    python3 - "$STATUS" "${repo_lenses:-}" "${npm_lenses:-}" "${npm_version:-}" "${site_lenses:-}" "${drift_line:-}" "$cands" "$filed" <<'PY' 2>/dev/null || true
import json,sys,datetime
p,repo,npmc,npmv,site,drift,cands,filed=sys.argv[1:9]
json.dump({"generated_at":datetime.datetime.now(datetime.timezone.utc).isoformat(),
 "script":"audit-pack-daily.sh","repo_lenses":repo,"npm_lenses":npmc,"npm_version":npmv,
 "site_lenses":site,"drift":bool(drift),"drift_line":drift,"candidates":int(cands),"filed":int(filed)},
 open(p,"w"),indent=1)
PY
  fi
  if [ "$NOTIFY" = "1" ] && [ "$DRY_RUN" != "1" ]; then
    if [ -n "$drift_line" ] || [ "$filed" -gt 0 ] || [ -n "${DEAD_SOURCES:-}" ] || [ "$ALWAYS" = "1" ]; then
      local notify="$(cd "$(dirname "$0")" && pwd)/notify.sh"
      [ -x "$notify" ] && "$notify" "Audit pack" "$line" >/dev/null 2>&1 || true
    fi
  fi
}

_say "audit-pack-daily ($(date '+%Y-%m-%d %H:%M')) dry=$DRY_RUN"
case "$PHASE" in
  drift) phase_drift ;;
  mine) phase_mine ;;
  propose) phase_mine >/dev/null; phase_propose ;;
  report) phase_report ;;
  all) phase_drift; phase_mine; phase_propose; phase_report ;;
  *) _say "unknown phase '$PHASE'"; exit 2 ;;
esac
exit 0
