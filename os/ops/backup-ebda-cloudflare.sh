#!/usr/bin/env bash
# Nightly pull of Ebda Store's Cloudflare backups (StoreDO + D1 exports in R2) to this Mac, so a Cloudflare
# ACCOUNT loss is recoverable (Ebda INFRA-CF-1 gap G8). Modelled on the retired managed Postgres dump job: caffeinate, loud
# failure, one page per run, keeps 30 days, content assertions instead of "the file exists".
#
# What it does
#   1. rclone copy (never sync/delete) R2 ebda-private/{store-do-backups,d1-backups,ops-reports} -> MIRROR
#   2. VERIFY every manifest of the last 2 days (rule N11): per table, line count (minus the header line)
#      == manifest rows AND sha256 == manifest sha256; a PAGED table (`parts`) is verified part by part (count, each
#      part's sha256 + rows, summed rows, table digest). A day folder without manifest.json is incomplete.
#   3. FRESHNESS: each store / D1 database must have a verified day <= 2 days old.
#   4. COLLAPSE: total rows < half of the previous day's (and previous > 10) is an error, not a backup.
#   5. SWEEP REPORT: the Worker's own ops-reports/backup-sweep/<day>.json must say ok:true.
#   6. Prune day folders older than KEEP days.
#
# Credentials (chmod 600, OUTSIDE ~/Desktop): $EBDA_R2_PULL_CREDS (default ~/.claude/.ebda-r2-pull-creds) with
#   R2_ACCOUNT_ID=69188202efc4df480140dd76545aa3ab  R2_ACCESS_KEY_ID=...  R2_SECRET_ACCESS_KEY=...
# an R2 API token, Object READ ONLY, scoped to bucket ebda-private. (The Ebda OS backup creds belong to a
# DIFFERENT Cloudflare account and cannot read this bucket, checked 2026-10-24.)
#
# Daily via launchd: ops/launchd/${OS_LAUNCHD_PREFIX}.ebda-cf-backup.plist (07:15 local = after the Worker 03:00 UTC sweep).  Manual: bash ops/backup-ebda-cloudflare.sh
# Test seam: EBDA_CF_BACKUP_SRC=<local dir laid out like the bucket> replaces R2 (ops/tests/backup-ebda-cloudflare.test.sh).

# shellcheck source=lib/os-config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/os-config.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-config.sh" 2>/dev/null || true
command -v os_config_load >/dev/null 2>&1 && os_config_load
if [ -z "${BACKUP_CAFFEINATED:-}" ] && command -v caffeinate >/dev/null 2>&1; then
  export BACKUP_CAFFEINATED=1
  exec caffeinate -i -- "$0" "$@"
fi

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/backup-projects.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/backup-projects.sh" 2>/dev/null || true

_ts()   { date +%Y-%m-%dT%H:%M:%S%z; }
stamp() { printf '%s backup-ebda-cloudflare: %s\n' "$(_ts)" "$*"; }

ROOT="${EBDA_CF_BACKUP_ROOT:-$OS_PROJECTS_DIR/_backups/ebda-cloudflare}"
MIRROR="$ROOT/mirror"
KEEP="${EBDA_CF_BACKUP_KEEP:-30}"
CREDS="${EBDA_R2_PULL_CREDS:-$HOME/.claude/.ebda-r2-pull-creds}"
SRC="${EBDA_CF_BACKUP_SRC:-}"
BUCKET="${EBDA_R2_BUCKET:-ebda-private}"
PREFIXES="store-do-backups d1-backups ops-reports/backup-sweep"

page() { # one page per run; the outcome of the send is reported, never swallowed
  if command -v backup_alert >/dev/null 2>&1; then backup_alert "$SCRIPT_DIR" "$1" "$2" || true
  else echo "ALERT NOT SENT (backup_alert unavailable): $1: $2" >&2; fi
}

FAILS=()
fail() { FAILS+=("$1"); stamp "ERROR: $1"; }

# ---- 1. pull ---------------------------------------------------------------------------------------------
if [ -n "$SRC" ]; then
  remote="$SRC"
else
  if [ ! -f "$CREDS" ]; then
    stamp "FATAL: credentials file $CREDS missing; NOTHING was pulled (a declared-but-uninstalled backup fails open)." >&2
    page "🚨 Ebda Cloudflare backup did NOT run" "credentials file missing at $CREDS. The nightly Mac copy of the Ebda R2 backups did not happen. Create an R2 read-only token for bucket $BUCKET (see header of ops/backup-ebda-cloudflare.sh)."
    exit 2
  fi
  command -v rclone >/dev/null 2>&1 || { stamp "FATAL: rclone missing" >&2; page "🚨 Ebda Cloudflare backup did NOT run" "rclone is not installed on this Mac."; exit 2; }
  # shellcheck disable=SC1090
  . "$CREDS"
  : "${R2_ACCOUNT_ID:?}" "${R2_ACCESS_KEY_ID:?}" "${R2_SECRET_ACCESS_KEY:?}"
  export RCLONE_CONFIG_EBDAR2_TYPE=s3 RCLONE_CONFIG_EBDAR2_PROVIDER=Cloudflare \
    RCLONE_CONFIG_EBDAR2_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" \
    RCLONE_CONFIG_EBDAR2_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY" \
    RCLONE_CONFIG_EBDAR2_ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com" \
    RCLONE_CONFIG_EBDAR2_NO_CHECK_BUCKET=true
  remote="EBDAR2:$BUCKET"
fi

mkdir -p "$MIRROR" "$ROOT"
STAGE="$ROOT/.staging"
rm -rf "$STAGE"; mkdir -p "$STAGE"
stamp "start - pulling ${PREFIXES} from $([ -n "$SRC" ] && echo "$SRC" || echo "R2:$BUCKET")"
for p in $PREFIXES; do
  mkdir -p "$STAGE/$p"
  if [ -n "$SRC" ]; then   # test seam: the "bucket" is a local directory
    if [ -d "$SRC/$p" ]; then cp -R "$SRC/$p/." "$STAGE/$p/" 2>"$ROOT/.rclone.err"; rc=$?; else rc=3; : >"$ROOT/.rclone.err"; fi
  else
    rclone copy "$remote/$p" "$STAGE/$p" --max-age "$((KEEP))d" --quiet 2>"$ROOT/.rclone.err"; rc=$?
  fi
  # rc 3 = directory not found: nothing written under that prefix yet (no store on StoreDO, no D1 bound).
  # Pre-cutover that is the normal state; "nothing to verify" below still fails an entirely empty mirror.
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 3 ]; then
    fail "pull of $p failed (rc=$rc): $(tail -1 "$ROOT/.rclone.err" | sed -E 's/(key|secret)[^ ]*//Ig')"
  fi
done

# WRITE-ONCE mirror: a file that already exists in the mirror is NEVER overwritten. The pull lands in a
# scratch dir; only files the mirror has not seen are moved in. A file that exists with different bytes means
# R2 (or the transfer) changed something already backed up: alert, keep the good local copy. Exception: the
# Worker's sweep reports (ops-reports/) are rewritten when the sweep re-runs the same day; they are a signal,
# not a backup, so they are refreshed in place.
while IFS= read -r -d '' f; do
  rel="${f#"$STAGE"/}"; dest="$MIRROR/$rel"
  if [ -e "$dest" ]; then
    if cmp -s "$f" "$dest"; then continue; fi
    case "$rel" in
      ops-reports/*) cp "$f" "$dest" ;;
      *) fail "IMMUTABILITY VIOLATION: $rel differs from the copy already on this Mac; the local copy was kept" ;;
    esac
  else
    mkdir -p "$(dirname "$dest")"; mv "$f" "$dest"
  fi
done < <(find "$STAGE" -type f -print0)
rm -rf "$STAGE"

# ---- 2. verify -------------------------------------------------------------------------------------------
sha() { shasum -a 256 "$1" | awk '{print $1}'; }
today_epoch() { date -u +%s; }
day_epoch() { date -u -j -f %Y-%m-%d "$1" +%s 2>/dev/null || date -u -d "$1" +%s; }
NOW="$(today_epoch)"

# verify_parts <manifest> <dir> <table> <rows> <table sha256>: a PAGED table (manifest.tables[t].parts, Worker
# `<table>.part-NNNN.ndjson`, P2-4) is verified part by part, failing CLOSED: the part count in the manifest must
# equal the part files on disk (a missing OR an extra part fails), every part's sha256 and body line count must
# match, the part rows must add up to the table rows, and the table sha256 must equal the Worker's `tableDigest`
# = sha256 of the part sha256s joined by "\n".
verify_parts() {
  local m="$1" dir="$2" t="$3" rows="$4" want_sha="$5" n on_disk f pr psha got body sum=0 shas="" listing
  n="$(jq -r --arg t "$t" '.tables[$t].parts | if type == "array" then length else -1 end' "$m")"
  [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -gt 0 ] || { stamp "  $m: $t parts is not a non-empty array" >&2; return 1; }
  on_disk="$(find "$dir" -maxdepth 1 -type f -name "$t.part-*.ndjson" | grep -c .)" || on_disk=0
  [ "$on_disk" -eq "$n" ] || { stamp "  $m: $t manifest lists $n parts but $on_disk part files are on disk" >&2; return 1; }
  listing="$(jq -r --arg t "$t" '.tables[$t].parts[] | [(.file // ""), (.rows | tostring), (.sha256 // "")] | @tsv' "$m")" \
    || { stamp "  $m: $t parts unreadable" >&2; return 1; }
  while IFS=$'\t' read -r f pr psha; do
    case "$f" in "$t".part-*.ndjson) ;; *) stamp "  $m: $t has an unsafe part file name '$f'" >&2; return 1 ;; esac
    case "$f" in */*|*..*) stamp "  $m: $t has an unsafe part file name '$f'" >&2; return 1 ;; esac
    [[ "$pr" =~ ^[0-9]+$ ]] || { stamp "  $m: $f rows '$pr' is not an integer" >&2; return 1; }
    [[ "$psha" =~ ^[0-9a-f]{64}$ ]] || { stamp "  $m: $f sha256 is not 64 hex chars" >&2; return 1; }
    [ -f "$dir/$f" ] || { stamp "  $m: $f missing" >&2; return 1; }
    got="$(sha "$dir/$f")"
    [ "$got" = "$psha" ] || { stamp "  $m: $f checksum differs" >&2; return 1; }
    body="$(grep -c . "$dir/$f")"
    [ "$((body - 1))" -eq "$pr" ] || { stamp "  $m: $f has $((body - 1)) rows, manifest says $pr" >&2; return 1; }
    sum=$((sum + pr)); shas="${shas:+$shas$'\n'}$psha"
  done <<<"$listing"
  [ "$sum" -eq "$rows" ] || { stamp "  $m: $t parts hold $sum rows, manifest says $rows" >&2; return 1; }
  got="$(printf '%s' "$shas" | shasum -a 256 | awk '{print $1}')"
  [ "$got" = "$want_sha" ] || { stamp "  $m: $t table digest differs from its parts" >&2; return 1; }
}

# verify_manifest <manifest.json> -> prints total rows on success, returns 1 on any mismatch. Fails CLOSED:
# a manifest with no tables, a non-integer row count or a malformed sha256 is a failure, never a vacuous pass.
verify_manifest() {
  local m="$1" dir t rows want_sha body_lines got total=0 n=0 listing
  dir="$(dirname "$m")"
  jq -e '.tables | type == "object" and length > 0' "$m" >/dev/null 2>&1 \
    || { stamp "  $m: manifest has no tables object" >&2; return 1; }
  listing="$(jq -r '.tables | to_entries[] | [.key, (.value.rows | tostring), (.value.sha256 // "")] | @tsv' "$m")" \
    || { stamp "  $m: manifest unreadable" >&2; return 1; }
  [ -n "$listing" ] || { stamp "  $m: manifest lists no tables" >&2; return 1; }
  while IFS=$'\t' read -r t rows want_sha; do
    n=$((n + 1))
    case "$t" in ''|*/*|*..*) stamp "  $m: unsafe table name '$t'" >&2; return 1 ;; esac
    [[ "$rows" =~ ^[0-9]+$ ]] || { stamp "  $m: $t rows '$rows' is not an integer" >&2; return 1; }
    [[ "$want_sha" =~ ^[0-9a-f]{64}$ ]] || { stamp "  $m: $t sha256 is not 64 hex chars" >&2; return 1; }
    if [ "$(jq -r --arg t "$t" '.tables[$t] | has("parts")' "$m")" = "true" ]; then
      verify_parts "$m" "$dir" "$t" "$rows" "$want_sha" || return 1
    else
      [ -f "$dir/$t.ndjson" ] || { stamp "  $m: $t.ndjson missing" >&2; return 1; }
      got="$(sha "$dir/$t.ndjson")"
      [ "$got" = "$want_sha" ] || { stamp "  $m: $t checksum differs" >&2; return 1; }
      body_lines="$(grep -c . "$dir/$t.ndjson")"
      [ "$((body_lines - 1))" -eq "$rows" ] || { stamp "  $m: $t has $((body_lines - 1)) rows, manifest says $rows" >&2; return 1; }
    fi
    total=$((total + rows))
  done <<<"$listing"
  [ "$n" -gt 0 ] || { stamp "  $m: zero tables verified" >&2; return 1; }
  echo "$total"
}

OK_UNITS=0
check_unit() { # <label> <unit dir holding <day>/manifest.json>
  local label="$1" udir="$2" newest="" prev="" d m rows prevrows=""
  # newest two day folders that HAVE a manifest (a folder without one is an incomplete backup, ignored)
  for d in $(ls -1 "$udir" 2>/dev/null | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' | sort -r); do
    # A day folder dated in the future (beyond 1 day of clock skew) can never be "newest": it would mask a
    # stale unit and make the age negative. It is an error in its own right.
    if [ "$(( $(day_epoch "$d") - NOW ))" -gt 86400 ]; then fail "$label: day folder $d is dated in the future"; continue; fi
    [ -f "$udir/$d/manifest.json" ] || continue
    if [ -z "$newest" ]; then newest="$d"; elif [ -z "$prev" ]; then prev="$d"; break; fi
  done
  if [ -z "$newest" ]; then fail "$label: no complete backup (no day folder with a manifest)"; return; fi
  local age=$(( (NOW - $(day_epoch "$newest")) / 86400 ))
  if [ "$age" -lt 0 ]; then fail "$label: negative age for $newest"; return; fi
  if [ "$age" -gt 2 ]; then fail "$label: newest verified backup is $newest (${age}d old, limit 2d)"; return; fi
  if ! rows="$(verify_manifest "$udir/$newest/manifest.json")"; then fail "$label: $newest FAILED verification"; return; fi
  if [ -n "$prev" ] && prevrows="$(verify_manifest "$udir/$prev/manifest.json" 2>/dev/null)" \
     && [ "$prevrows" -gt 10 ] && [ "$rows" -lt $((prevrows / 2)) ]; then
    fail "$label: row count COLLAPSED $prevrows -> $rows ($prev -> $newest)"; return
  fi
  OK_UNITS=$((OK_UNITS + 1))
  stamp "ok $label - $newest, $rows rows verified"
}

for s in "$MIRROR"/store-do-backups/*/; do [ -d "$s" ] && check_unit "store $(basename "$s")" "${s%/}"; done
for s in "$MIRROR"/d1-backups/*/;       do [ -d "$s" ] && check_unit "d1 $(basename "$s")" "${s%/}"; done
if [ "$OK_UNITS" -eq 0 ] && [ "${#FAILS[@]}" -eq 0 ]; then
  fail "nothing to verify: the mirror holds no store or D1 backup at all (is the Worker's backup-sweep running?)"
fi

# ---- 5. the Worker's own sweep report --------------------------------------------------------------------
latest_report="$(ls -1 "$MIRROR"/ops-reports/backup-sweep/*.json 2>/dev/null | sort | tail -1)"
if [ -n "$latest_report" ]; then
  [ "$(jq -r '.ok' "$latest_report" 2>/dev/null)" = "true" ] || fail "Worker backup-sweep report $(basename "$latest_report") says ok:false"
else
  fail "no ops-reports/backup-sweep report in the mirror (the 03:00 Cron has not run)"
fi

# ---- 6. prune --------------------------------------------------------------------------------------------
cutoff=$((NOW - KEEP * 86400))
for d in "$MIRROR"/store-do-backups/*/[0-9]*-*-* "$MIRROR"/d1-backups/*/[0-9]*-*-*; do
  [ -d "$d" ] || continue
  [ "$(day_epoch "$(basename "$d")" 2>/dev/null || echo "$NOW")" -lt "$cutoff" ] && rm -rf "$d"
done

if [ "${#FAILS[@]}" -gt 0 ]; then
  stamp "done - ${OK_UNITS} ok, ${#FAILS[@]} problem(s)."
  page "🚨 Ebda Cloudflare backup problem" "${#FAILS[@]} problem(s): $(printf '%s; ' ${FAILS[@]+"${FAILS[@]}"}). ${OK_UNITS} unit(s) verified. Detail: ~/Library/Logs/ebda-os-ebda-cf-backup.log"
  exit 1
fi
stamp "done - ${OK_UNITS} ok, 0 problems."
