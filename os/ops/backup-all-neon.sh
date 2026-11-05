#!/usr/bin/env bash
# FREE local backups of every Force Neon DB to ~/Desktop/projects/_backups/<name>/.
# Self-contained: pulls the REAL direct connection string from Neon (neonctl,
# already authed) — no dependence on repo .env files (which can be placeholders
# or pooled URLs pg_dump rejects). Keeps the 30 most recent per project, prunes
# older, so storage never blows up. Requires pg_dump >= server (Neon = PG17).
#
# Daily via launchd: ~/Library/LaunchAgents/com.ebda.os.neon-backup.plist
# Manual:  bash ~/.claude/scripts/backup-all-neon.sh [--quiet]

# ── stay awake for the whole run ─────────────────────────────────────────────
# This job fires at 03:30 when the Mac is asleep. launchd runs it during a Power
# Nap or deferred-wake window, and the machine is free to re-sleep mid-dump —
# which kills the long-lived Postgres connection partway through:
#
#   server closed the connection unexpectedly
#   SSL SYSCALL error: Operation timed out
#
# That is exactly how the fleet backup failed every night from 2026-08-04
# (0 succeeded, 6 failed) while running perfectly by hand: FWB died 42 minutes in,
# CRM 98 minutes in against the most distant region. Nothing was wrong with Neon,
# the credentials, or pg_dump — the host went back to sleep.
#
# Re-exec under caffeinate so an idle-sleep assertion is held for the entire run.
# -i is idle sleep only: a lid close or a deliberate sleep still wins, so this
# cannot keep the machine awake against the user's wishes.
if [ -z "${BACKUP_CAFFEINATED:-}" ] && command -v caffeinate >/dev/null 2>&1; then
  export BACKUP_CAFFEINATED=1
  exec caffeinate -i -- "$0" "$@"
fi


set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/os-state.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-state.sh" 2>/dev/null || true
# host pre-flight (2026-09-16) — "0 succeeded, 5 failed" reads as five sick
# databases; on 2026-09-16 it meant this Mac had lost DNS and neonctl timed out
# for every project.
. "$SCRIPT_DIR/lib/net-probe.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/net-probe.sh" 2>/dev/null || true
# The project list + the one way this job pages Ahmad.
. "$SCRIPT_DIR/lib/backup-projects.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/backup-projects.sh" 2>/dev/null || true

# Every line carries a timestamp. Until 2026-09-19 this log had NONE — 21 lines,
# four bare "Done. N succeeded, N failed." entries and no dates anywhere — so the
# only way to tell which run a line belonged to was to compare dump-file mtimes
# by hand. That ambiguity already produced a wrong "three nights in a row" claim.
_ts()   { date +%Y-%m-%dT%H:%M:%S%z; }
stamp() { printf '%s backup-all-neon: %s\n' "$(_ts)" "$*"; }

# FAIL LOUD if the list is absent — a missing list would otherwise mean "back up
# nothing", succeed, and look identical to a clean run (a declared-but-uninstalled
# gate fails open, silently). NOTHING backed up is the incident, so it pages.
if ! command -v backup_neon_entries >/dev/null 2>&1; then
  stamp "FATAL — lib/backup-projects.sh not found; refusing to run with an unknown project list (run ops/install.sh)." >&2
  if [ -x "$SCRIPT_DIR/notify.sh" ]; then
    "$SCRIPT_DIR/notify.sh" "🚨 Neon backup did NOT run" \
      "lib/backup-projects.sh is missing on this machine, so the nightly dump could not determine which databases to back up. NOTHING was backed up tonight. Fix: ops/install.sh" \
      || stamp "ALERT SEND FAILED for the missing-project-list FATAL" >&2
  else
    stamp "ALERT NOT SENT — notify.sh missing or not executable at $SCRIPT_DIR/notify.sh" >&2
  fi
  exit 2
fi
# NEON_API_KEY → neonctl runs headless (no browser OAuth fallback from launchd)
[ -f "${OS_SERVICES_ENV:-$HOME/.whisky-services.env}" ] && { set -a; . "${OS_SERVICES_ENV:-$HOME/.whisky-services.env}"; set +a; } 2>/dev/null || true   # set -a: children (neonctl, node, curl wrappers) must see the keys
export NEON_API_KEY="${NEON_API_KEY:-}"

# TCC canary (2026-07-12): abort when the launchd context cannot see ~/Desktop
OS_JOB_NAME=backup-all-neon
if command -v require_projects_access_critical >/dev/null 2>&1; then require_projects_access_critical || exit 0; fi

# The postgres client + neonctl live in Homebrew.
#
# postgresql@18 FIRST (measured 2026-09-19): Neon has started creating projects
# on PG18, and pg_dump refuses to dump a server newer than itself —
# "server version: 18.6; pg_dump version: 17.11" aborted al-assriya-landing
# outright. A newer client dumps an older server happily, so @18 covers the PG17
# projects too; @17 stays as the fallback for a machine without @18 installed.
# Overridable ONLY so the test suite can point this at stub binaries — a test
# that reached the real neonctl would talk to production Neon.
export PATH="${NEON_BACKUP_BIN_PATH:-/opt/homebrew/opt/postgresql@18/bin:/opt/homebrew/opt/postgresql@17/bin:/opt/homebrew/bin}:$PATH"

# Default Neon org. A "name:project-id:org-id" entry in lib/backup-projects.sh
# overrides this per-project (ebda lives under a separate Neon org).
ORG="org-lingering-river-25973882"
ROOT="${HOME}/Desktop/projects/_backups"
KEEP="${NEON_BACKUP_KEEP:-30}"  # cap local dumps per project (~1 month at daily; Ahmad 2026-07-01)

# ── Off-machine layer: encrypt + push each fresh dump to a PRIVATE R2 bucket ──
# Safe no-op until the creds file exists, so this never breaks the local backup.
# Creds file (chmod 600, OUTSIDE ~/Desktop): R2_ACCOUNT_ID, R2_ACCESS_KEY_ID,
# R2_SECRET_ACCESS_KEY, R2_BUCKET, BACKUP_ENCRYPTION_KEY.
R2_CREDS="${R2_BACKUP_CREDS:-$HOME/.claude/.r2-backup-creds}"
push_to_r2() {
  local proj="$1" gz="$2"
  [ -f "$R2_CREDS" ] || return 0
  command -v rclone >/dev/null 2>&1 || { echo "  (r2: rclone missing, skip)"; return 0; }
  # shellcheck disable=SC1090
  ( . "$R2_CREDS"
    [ -n "${R2_ACCOUNT_ID:-}" ] && [ -n "${R2_ACCESS_KEY_ID:-}" ] \
      && [ -n "${R2_SECRET_ACCESS_KEY:-}" ] && [ -n "${R2_BUCKET:-}" ] \
      && [ -n "${BACKUP_ENCRYPTION_KEY:-}" ] || { echo "  (r2: creds incomplete, skip)"; return 0; }
    local enc="${gz}.enc"
    openssl enc -aes-256-cbc -salt -pbkdf2 -pass "pass:${BACKUP_ENCRYPTION_KEY}" -in "$gz" -out "$enc" 2>/dev/null || { echo "  (r2: encrypt failed)"; return 0; }
    # rclone S3 remote via env-config. NO_CHECK_BUCKET=true is REQUIRED for a
    # bucket-scoped R2 token (Object R/W only) — else rclone's CreateBucket
    # existence probe 403s. Do NOT use the inline ":s3,...:" string: rclone
    # mis-parses the https:// endpoint ("Custom endpoint `https` not a valid URI").
    export RCLONE_CONFIG_R2_TYPE=s3 RCLONE_CONFIG_R2_PROVIDER=Cloudflare \
      RCLONE_CONFIG_R2_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" \
      RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY" \
      RCLONE_CONFIG_R2_ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com" \
      RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true
    if rclone copyto "$enc" "R2:${R2_BUCKET}/${proj}/$(basename "$enc")" 2>/dev/null; then
      rclone delete --min-age 30d "R2:${R2_BUCKET}/${proj}/" 2>/dev/null || true  # 1-month cloud retention
      [ -n "$QUIET" ] || echo "  ☁ pushed to R2 (${proj})"
    else
      echo "  (r2: upload failed for ${proj})"
    fi
    rm -f "$enc"
  )
}
QUIET="${1:-}"

# friendly-name : neon-project-id — from lib/backup-projects.sh, which is the
# SAME list os-selftest.sh checks for freshness. They used to be two lists: this
# job dumped six projects while the self-test watched two, so four production
# databases could have stopped being backed up with every gate still green.
PROJECTS=()
while IFS= read -r _entry; do
  [ -n "$_entry" ] && PROJECTS+=("$_entry")
done < <(backup_neon_entries)
if [ "${#PROJECTS[@]}" -eq 0 ]; then
  stamp "FATAL — the project list resolved to ZERO projects; nothing was dumped." >&2
  backup_alert "$SCRIPT_DIR" "🚨 Neon backup did NOT run" \
    "the project list resolved to ZERO projects, so no database was dumped tonight. Check ops/lib/backup-projects.sh on this machine." || true
  exit 2
fi

stamp "start — ${#PROJECTS[@]} project(s)"

OK=0
FAIL=0
FAILED_NAMES=()
# Record WHICH project failed, not just how many: the alert has to name them, and
# "0 succeeded, 5 failed" is what made a local network outage read as five sick
# databases in the first place.
fail_project() { FAIL=$((FAIL + 1)); FAILED_NAMES+=("$1"); }

# Guarded expansion. Expanding an empty array unguarded ABORTS under set -u on
# bash 3.2 (macOS /bin/bash). Unreachable here — the count check above gates it —
# but ops/lib/__tests__/empty-array-guard.test.sh forbids the shape outright, and
# it is right to: this is how deploy-drift died silently for 32h.
# (That gate is a regex over the whole file, comments included, so this note
# deliberately does not spell the forbidden expansion out.)
for entry in ${PROJECTS[@]+"${PROJECTS[@]}"}; do
  name="${entry%%:*}"
  _rest="${entry#*:}"
  if [ "$_rest" != "${_rest%%:*}" ]; then
    pid="${_rest%%:*}"
    org="${_rest#*:}"
  else
    pid="$_rest"
    org="$ORG"
  fi

  # A Neon ORG API key is scoped to ONE org (confirmed 2026-10-10: the
  # default $NEON_API_KEY, scoped to org-lingering-river-25973882, answers
  # ebda's org-proud-silence-64969971 with "not allowed to perform this
  # action on the organization" — --org-id alone cannot override a key's own
  # scope). A project whose org differs from $ORG needs ITS OWN key: name it
  # NEON_API_KEY_<FRIENDLY-NAME-UPPERCASED, non-alnum→_> (e.g. NEON_API_KEY_EBDA)
  # in the same secrets file as the default. Falls back to the default key
  # when no override is set, so every existing project is unaffected.
  _key_var="NEON_API_KEY_$(printf '%s' "$name" | tr '[:lower:]-' '[:upper:]_' | tr -cd 'A-Z0-9_')"
  _key_override="${!_key_var:-}"
  if [ -n "$_key_override" ]; then
    neon_key="$_key_override"
  else
    neon_key="$NEON_API_KEY"
  fi

  # A parked project must stay parked. pg_dump opens a real connection, so backing
  # up a paused DB wakes its compute every single night and silently undoes the
  # saving. Skipping is safe precisely BECAUSE it is paused: nothing is writing, so
  # the last backup taken before the pause still represents the data exactly.
  # Un-pausing re-arms this automatically — the marker is the only switch.
  if backup_project_paused "$name"; then
    stamp "SKIP $name — paused (see ops/wbs-power.sh status); last backup still current"
    continue
  fi

  dir="${ROOT}/${name}"
  mkdir -p "$dir"
  out="${dir}/$(date -u +%Y%m%dT%H%M%SZ).sql.gz"

  # Always dump as the OWNER (neondb_owner) — full data, not the restricted
  # RLS app role (e.g. FWB's force_app). Required where a project has >1 role.
  url="$(NEON_API_KEY="$neon_key" neonctl connection-string --project-id "$pid" --org-id "$org" --role-name neondb_owner 2>/dev/null)"
  if [ -z "$url" ]; then
    # This is a FAILURE, not a warning: no connection string means no dump for
    # this project tonight. It was logged as "WARN:" and then folded into a
    # "Done. N succeeded" summary — which is exactly how the 2026-09-17/18
    # offline nights read as routine. It counts, and it pages.
    stamp "ERROR: no connection string from Neon for $name ($pid) — this project was NOT backed up"
    fail_project "$name"; continue
  fi
  case "$url" in
    *sslmode=*) ;;
    *\?*) url="${url}&sslmode=require" ;;
    *) url="${url}?sslmode=require" ;;
  esac

  [ -n "$QUIET" ] || stamp "backing up $name -> $out"
  if pg_dump "$url" --no-owner --no-privileges --clean --if-exists 2>"/tmp/pgdump-${name}.err" | gzip -9 >"$out"; then
    # `wc -c`, not `stat -f%z`: -f is a BSD extension GNU stat rejects, so on any
    # non-macOS host the size read silently became 0 and every healthy dump was
    # condemned as "too small".
    sz=$(wc -c <"$out" 2>/dev/null | tr -d ' ')
    [ -n "$sz" ] || sz=0
    if [ "$sz" -lt 200 ]; then
      stamp "ERROR: $name dump too small (${sz}b): $(tail -1 "/tmp/pgdump-${name}.err")"
      rm -f "$out"; fail_project "$name"; continue
    fi

    # ── CONTENT ASSERTION ────────────────────────────────────────────────────
    # A size check is NOT a backup check. 2026-08-02: the Force Media CRM prod
    # DB was wiped, and this script archived 30 consecutive SCHEMA-ONLY dumps
    # (3.5KB each — far above the 200b floor) reporting success every time. The
    # DR that was supposed to make the wipe survivable had been backing up an
    # empty database for five weeks, silently.
    # So: count actual data rows inside the dump. In pg_dump plain format each
    # table's data sits between "COPY ... FROM stdin;" and a lone "\.".
    rows=$(gzip -dc "$out" 2>/dev/null | awk '
      /^COPY .* FROM stdin;/ { inblk=1; next }
      inblk && /^\\\.$/     { inblk=0; next }
      inblk                  { n++ }
      END                    { print n+0 }')
    prev=$(ls -t "$dir"/*.sql.gz 2>/dev/null | sed -n 2p)
    prevrows=""
    if [ -n "$prev" ]; then
      prevrows=$(gzip -dc "$prev" 2>/dev/null | awk '
        /^COPY .* FROM stdin;/ { inblk=1; next }
        inblk && /^\\\.$/     { inblk=0; next }
        inblk                  { n++ }
        END                    { print n+0 }')
    fi

    # Compare rows against TABLE COUNT, not against zero. The CRM dump that
    # hid a total data loss for five weeks was not empty — it held exactly one
    # row (a SystemState bookkeeping record), so a "rows == 0" test would have
    # sailed straight past it. Any real database has more rows than tables.
    tables=$(gzip -dc "$out" 2>/dev/null | grep -c '^CREATE TABLE ')
    if [ "$rows" -lt "$tables" ]; then
      stamp "ERROR: $name dump has ${rows} data rows across ${tables} tables — effectively schema-only. The database is empty, or reachable-but-wrong. NOT a valid backup."
      fail_project "$name"
      # Keep the file: it is evidence of when the data disappeared.
    elif [ -n "$prevrows" ] && [ "$prevrows" -gt 0 ] && [ "$rows" -lt $((prevrows / 2)) ]; then
      stamp "ERROR: $name row count COLLAPSED ${prevrows} -> ${rows} since the previous dump. Investigate before trusting this backup."
      fail_project "$name"
    else
      OK=$((OK + 1))
    fi
    ls -t "$dir"/*.sql.gz 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -f 2>/dev/null
    push_to_r2 "$name" "$out"   # off-machine encrypted copy (no-op until creds set)
    # Stamped per-project result, printed under --quiet TOO: without it the log
    # cannot answer "did a client project get backed up last night?" at all.
    stamp "ok $name — $(du -h "$out" | cut -f1), ${rows} data rows ($(ls "$dir"/*.sql.gz 2>/dev/null | wc -l | tr -d ' ') kept)"
  else
    stamp "ERROR: pg_dump failed for $name: $(tail -1 "/tmp/pgdump-${name}.err")"
    rm -f "$out"; fail_project "$name"
  fi
done

echo
# Say what actually happened. The EXIT STATUS is deliberately unchanged
# (Ruling M-7): a backup that did not happen is still a real DR gap, however
# local the cause — only the wording is corrected.
#
# ── WHO GETS PAGED, AND HOW OFTEN ────────────────────────────────────────────
# At most ONE Telegram message per run, never one per project (Ruling B-3).
# On 2026-09-17 and 2026-09-18 this job did not run at all and said so only in a
# log nobody reads; Ahmad found out because someone went looking. A backup that
# did not happen now pages at the moment of failure.
ALERT_TITLE=""
ALERT_BODY=""
if [ "$FAIL" -gt 0 ] && [ "$OK" -eq 0 ] \
   && command -v host_online >/dev/null 2>&1 && ! host_online; then
  stamp "host offline — this Mac could not reach the network; backups did NOT run (${FAIL} project(s) affected). This is a LOCAL failure: Neon state is unknown, the databases are NOT known to be unhealthy."
  command -v write_status >/dev/null 2>&1 && write_status "neon-backup" "warn" \
    "host offline — ${FAIL} backup(s) did not run; Neon state unknown" '{"host_offline":true}'
  # ONE notice about the HOST — not N notices about N innocent databases.
  #
  # This deliberately departs from Ruling M-1 ("a blind monitor does not page"),
  # and the difference is what blindness MEANS for each job. For a monitor,
  # offline means the target's state is unknown, so there is nothing to report.
  # For this job, offline means THE WORK DID NOT HAPPEN — a real DR gap whatever
  # the cause, exactly as Ruling M-7 already reasoned when it kept the non-zero
  # exit. The send is bounded (notify.sh uses curl -m 15) and its outcome is
  # logged either way, so an undeliverable page costs 15s and leaves a record;
  # the 36h staleness check in os-selftest is the backstop that catches it the
  # next morning if the page could not go out.
  ALERT_TITLE="⚠️ Neon backup — monitoring blind"
  ALERT_BODY="host offline — this Mac could not reach the network; backups did NOT run (${FAIL} project(s) affected). Neon state is UNKNOWN: the databases are NOT known to be unhealthy. Backstop: os-selftest flags any project with no dump in 36h."
else
  stamp "done — ${OK} succeeded, ${FAIL} failed."
  if [ "$FAIL" -gt 0 ]; then
    _failed_list="$(printf '%s, ' ${FAILED_NAMES[@]+"${FAILED_NAMES[@]}"})"
    _failed_list="${_failed_list%, }"
    ALERT_TITLE="🚨 Neon backup FAILED"
    ALERT_BODY="${FAIL} of $(( OK + FAIL )) project(s) did NOT get a valid dump: ${_failed_list}. ${OK} succeeded. Detail (no credentials): ~/Library/Logs/forceai-neon-backup.log"
  fi
fi
# The send outcome is logged, never swallowed — a notify.sh failure at the exact
# moment a real backup failure needs paging is the worst time to have no signal.
if [ -n "$ALERT_TITLE" ]; then
  backup_alert "$SCRIPT_DIR" "$ALERT_TITLE" "$ALERT_BODY" || true
fi
[ $FAIL -eq 0 ]
