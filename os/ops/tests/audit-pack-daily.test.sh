#!/usr/bin/env bash
# The audit-pack cycle, tested where it can lie: a drift it must SEE, a candidate it
# must PRODUCE, a covered class it must NOT re-propose, an empty source it must ANNOUNCE,
# and a dry run that files nothing. Seeded inputs, no network, no gh.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../audit-pack-daily.sh"
PASS=0; FAIL=0
_check() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else echo "  FAIL: $1 — got '$2' want '$3'"; FAIL=$((FAIL+1)); fi; }

# ── drift ────────────────────────────────────────────────────────────────────
out="$(AUDIT_PACK_FAKE_REPO=37 AUDIT_PACK_FAKE_NPM=31 AUDIT_PACK_FAKE_SITE=37 DRY_RUN=1 bash "$SCRIPT" --phase drift 2>&1)"
_check "sees drift"            "$(echo "$out" | grep -c 'DRIFT: site says 37, npm ships 31')" "1"
out2="$(AUDIT_PACK_FAKE_REPO=37 AUDIT_PACK_FAKE_NPM=37 AUDIT_PACK_FAKE_SITE=37 DRY_RUN=1 bash "$SCRIPT" --phase drift 2>&1)"
_check "aligned when aligned"  "$(echo "$out2" | grep -c 'aligned: 37')" "1"
_check "no false drift"        "$(echo "$out2" | grep -c 'DRIFT:')" "0"
out3="$(AUDIT_PACK_FAKE_REPO=37 AUDIT_PACK_FAKE_NPM= AUDIT_PACK_FAKE_SITE=37 DRY_RUN=1 bash "$SCRIPT" --phase drift 2>&1)"
_check "unmeasured is not aligned" "$(echo "$out3" | grep -c 'aligned:')" "0"
_check "unmeasured says why"       "$(echo "$out3" | grep -cE 'skipped: npm')" "1"

# ── mine ─────────────────────────────────────────────────────────────────────
tmp="$(mktemp -d)"
cat > "$tmp/world-extras.json" <<'JSON'
{"findings":[
 {"class":"framework-eol","severity":"high","title":"Node 20 reaches EOL in 60 days","detail":"node 20.x"},
 {"class":"rls-missing","severity":"critical","title":"tenant table without row-level security","detail":"seeded"}
]}
JSON
# Seeded source list. These cases are about the state-file miner, and running
# them against the PRODUCTION config made them depend on what happens to be on
# this machine's disk: once a client-audit source existed, "an empty watchdog
# yields no candidate" started counting candidates mined from real client
# reports and failed for a reason that had nothing to do with the watchdog.
cat > "$tmp/sources.json" <<'JSON'
{"sources":[
 {"id":"os-watchdog","kind":"state-file","enabled":true,"paths":["world-extras.json"]},
 {"id":"video-matt-murphy","kind":"instagram","enabled":true,"profile":"https://example.invalid/x/","max_per_run":1}
]}
JSON
m="$(AUDIT_PACK_STATE="$tmp" AUDIT_PACK_SOURCES="$tmp/sources.json" AUDIT_PACK_LENS_IDS="rls,deps" AUDIT_PACK_SKIP_VIDEO=1 DRY_RUN=1 bash "$SCRIPT" --phase mine 2>&1)"
_check "new class is a candidate"  "$(echo "$m" | grep -c 'candidate: framework-eol')" "1"
_check "covered class is skipped"  "$(echo "$m" | grep -c 'covered by lens rls: rls-missing')" "1"
_check "video source is visible" "$(echo "$m" | grep -c 'video-matt-murphy')" "1"
# A dead ENABLED source must reach the report line (it used to say "aligned" while Murphy was dead).
printf '#!/bin/sh\necho "  skipped: video (session expired — open instagram.com in Chrome and log in again)"\n' > "$tmp/fake-video.sh"
printf '{"sources":[{"id":"video-matt-murphy","kind":"instagram","enabled":true,"profile":"https://example.invalid/x/","max_per_run":1}]}' > "$tmp/dead.json"
d="$(AUDIT_PACK_STATE="$tmp" AUDIT_PACK_SOURCES="$tmp/dead.json" AUDIT_PACK_VIDEO_LIB="$tmp/fake-video.sh" AUDIT_PACK_LENS_IDS="rls" \
     AUDIT_PACK_FAKE_REPO=37 AUDIT_PACK_FAKE_NPM=37 AUDIT_PACK_FAKE_SITE=37 DRY_RUN=1 bash "$SCRIPT" --phase all 2>&1)"
_check "dead source reaches the report" "$(echo "$d" | grep -c 'DEAD SOURCE: video-matt-murphy (session expired')" "1"
: > "$tmp/world-extras.json"
e="$(AUDIT_PACK_STATE="$tmp" AUDIT_PACK_SOURCES="$tmp/sources.json" AUDIT_PACK_LENS_IDS="rls" AUDIT_PACK_SKIP_VIDEO=1 DRY_RUN=1 bash "$SCRIPT" --phase mine 2>&1)"
_check "empty source announced"    "$(echo "$e" | grep -cE 'skipped: os-watchdog \((empty|unreadable)')" "1"
_check "empty yields no candidate" "$(echo "$e" | grep -c 'candidate:')" "0"

# ── advisory-feed + client-audit (the two sources Ahmad added 2026-09-23) ────
# Both are mined OFFLINE here. A source that can only be exercised against the
# network is a source nobody runs, and an untested miner fails quietly.
advtmp="$(mktemp -d)"
cat > "$advtmp/feed.atom" <<'ATOM'
<feed><title>GitHub Advisory Database</title>
<entry><title>Laravel framework vulnerable to SQL injection</title><id>GHSA-aaaa-bbbb-cccc</id></entry>
<entry><title>guzzlehttp/guzzle cookie leak</title><id>CVE-2026-12345</id></entry>
</feed>
ATOM
cat > "$advtmp/sources.json" <<JSON
{"sources":[{"id":"advisories","kind":"advisory-feed","enabled":true,"max_per_run":25,"urls":["https://example.invalid/feed.atom"]}]}
JSON
a="$(AUDIT_PACK_STATE="$advtmp" AUDIT_PACK_SOURCES="$advtmp/sources.json" \
     AUDIT_PACK_FAKE_ADVISORIES="$advtmp/feed.atom" AUDIT_PACK_LENS_IDS="rls,deps" \
     AUDIT_PACK_SKIP_VIDEO=1 DRY_RUN=1 bash "$SCRIPT" --phase mine 2>&1)"
_check "advisory ids are parsed"      "$(echo "$a" | grep -c 'advisory: GHSA-aaaa-bbbb-cccc')" "1"
_check "CVE ids are parsed too"       "$(echo "$a" | grep -c 'advisory: CVE-2026-12345')" "1"
_check "ONE candidate for the feed"   "$(echo "$a" | grep -c 'candidate: dep-known-advisory')" "1"
_check "advisories recorded as data"  "$(grep -c 'GHSA-aaaa-bbbb-cccc' "$advtmp/audit-pack-advisories.tsv" 2>/dev/null)" "1"
# Run twice: an already-recorded advisory must not be re-announced.
a2="$(AUDIT_PACK_STATE="$advtmp" AUDIT_PACK_SOURCES="$advtmp/sources.json" \
      AUDIT_PACK_FAKE_ADVISORIES="$advtmp/feed.atom" AUDIT_PACK_LENS_IDS="rls,deps" \
      AUDIT_PACK_SKIP_VIDEO=1 DRY_RUN=1 bash "$SCRIPT" --phase mine 2>&1)"
_check "seen advisory is not repeated" "$(echo "$a2" | grep -c 'advisory: GHSA-aaaa-bbbb-cccc')" "0"
_check "recorded once, not twice"      "$(grep -c 'GHSA-aaaa-bbbb-cccc' "$advtmp/audit-pack-advisories.tsv")" "1"
# An empty feed must ANNOUNCE itself, never pass quietly.
: > "$advtmp/empty.atom"
a3="$(AUDIT_PACK_STATE="$advtmp" AUDIT_PACK_SOURCES="$advtmp/sources.json" \
      AUDIT_PACK_FAKE_ADVISORIES="$advtmp/empty.atom" AUDIT_PACK_LENS_IDS="rls" \
      AUDIT_PACK_SKIP_VIDEO=1 DRY_RUN=1 bash "$SCRIPT" --phase mine 2>&1)"
_check "empty advisory feed says so"  "$(echo "$a3" | grep -cE 'skipped: advisories')" "1"

clitmp="$(mktemp -d)"
mkdir -p "$clitmp/acme/reports"
cat > "$clitmp/acme/reports/security.md" <<'MD'
### SEC-004: Company portal has no authentication at all — IDOR by design
Body.
### SEC-011: SESSION_SECURE_COOKIE has no safe default
Body.
MD
cat > "$clitmp/sources.json" <<JSON
{"sources":[{"id":"client-audits","kind":"client-audit","enabled":true,"max_per_run":5,"roots":["$clitmp"]}]}
JSON
c="$(AUDIT_PACK_STATE="$clitmp" AUDIT_PACK_SOURCES="$clitmp/sources.json" \
     AUDIT_PACK_LENS_IDS="rls,deps" AUDIT_PACK_SKIP_VIDEO=1 DRY_RUN=1 \
     bash "$SCRIPT" --phase mine 2>&1)"
_check "client finding is a candidate" "$(echo "$c" | grep -c 'candidate: company-portal-authentication-idor')" "1"
_check "second finding too"            "$(echo "$c" | grep -c 'candidate: session-secure-cookie-safe')" "1"
# A class an existing lens already covers must NOT be re-proposed.
c2="$(AUDIT_PACK_STATE="$clitmp" AUDIT_PACK_SOURCES="$clitmp/sources.json" \
      AUDIT_PACK_LENS_IDS="company-portal-authentication-idor,deps" AUDIT_PACK_SKIP_VIDEO=1 \
      DRY_RUN=1 bash "$SCRIPT" --phase mine 2>&1)"
_check "covered class is not re-proposed" "$(echo "$c2" | grep -c 'candidate: company-portal-authentication-idor')" "0"
_check "and says which lens covers it"    "$(echo "$c2" | grep -c 'covered by lens company-portal-authentication-idor')" "1"
# No reports at all must ANNOUNCE itself.
empt="$(mktemp -d)"
cat > "$empt/sources.json" <<JSON
{"sources":[{"id":"client-audits","kind":"client-audit","enabled":true,"roots":["$empt/nothing-here"]}]}
JSON
c3="$(AUDIT_PACK_STATE="$empt" AUDIT_PACK_SOURCES="$empt/sources.json" AUDIT_PACK_LENS_IDS="rls" \
      AUDIT_PACK_SKIP_VIDEO=1 DRY_RUN=1 bash "$SCRIPT" --phase mine 2>&1)"
_check "no client reports says so"     "$(echo "$c3" | grep -cE 'skipped: client-audits')" "1"
# The hint is a HINT: the candidate is still proposed, with likely owners named.
# Trusting word overlap to SUPPRESS mis-attributed every time it was tried.
fleetstub="$(mktemp -d)"; mkdir -p "$fleetstub/lenses" "$fleetstub/rubric"
echo '{"id":"php-uploads","criteria":[]}' > "$fleetstub/lenses/php-uploads.json"
printf 'unrestricted file upload destination mimes max\n' > "$fleetstub/rubric/php-uploads.md"
echo '{"id":"rls","criteria":[]}' > "$fleetstub/lenses/rls.json"
h="$(AUDIT_PACK_STATE="$clitmp" AUDIT_PACK_SOURCES="$clitmp/sources.json" \
     AUDIT_PACK_FLEET="$fleetstub" AUDIT_PACK_LENS_IDS="rls,php-uploads" \
     AUDIT_PACK_SKIP_VIDEO=1 DRY_RUN=1 bash "$SCRIPT" --phase mine 2>&1)"
_check "candidate is still proposed"  "$(echo "$h" | grep -c 'candidate: company-portal-authentication-idor')" "1"
rm -rf "$fleetstub"
rm -rf "$advtmp" "$clitmp" "$empt"

# ── propose ──────────────────────────────────────────────────────────────────
cat > "$tmp/world-extras.json" <<'JSON'
{"findings":[
 {"class":"framework-eol","severity":"high","title":"Node 20 reaches EOL in 60 days","detail":"node 20.x"},
 {"class":"secret-in-ci-log","severity":"critical","title":"a token printed into a CI log","detail":"seeded"}
]}
JSON
p="$(AUDIT_PACK_STATE="$tmp" AUDIT_PACK_LENS_IDS="rls" AUDIT_PACK_MAX_PROPOSALS=1 AUDIT_PACK_SKIP_VIDEO=1 DRY_RUN=1 bash "$SCRIPT" --phase propose 2>&1)"
_check "dry run files nothing" "$(echo "$p" | grep -c 'DRY_RUN: would file issue')" "1"
_check "cap holds at 1"        "$(echo "$p" | grep -c 'cap reached')" "1"
_check "body carries the bar"  "$(echo "$p" | grep -c 'all four files')" "1"

echo "audit-pack-daily: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
