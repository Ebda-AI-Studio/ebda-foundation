# shellcheck shell=bash
# ops/lib/backup-projects.sh — the ONE list of databases that must have a fresh
# local dump, plus the one way a backup job pages Ahmad.
#
# WHY THIS FILE EXISTS: the dump job and the staleness check must read the SAME list.
# A checker that watches a subset of what the writer writes reports on a fleet it does not
# cover, and a list that is incomplete at the source is never noticed by "is every listed
# project backed up". Both halves read the list from here, so adding a project arms the dump
# AND the staleness check in one edit.
#
# THE RULE FOR THIS LIST: back up every LIVE project. A PAUSED project is
# excluded on purpose — a nightly pg_dump is a real connection, so dumping a
# paused Neon project restarts its billing clock every night and silently undoes
# the pause. A paused project is watched through backup_project_paused (which
# makes the freshness check SKIP it), never by pretending it has a fresh dump.

# ── the Neon projects that are dumped nightly ────────────────────────────────
# "friendly-name:neon-project-id[:neon-org-id]", one per line. friendly-name is also the
# directory under ~/Desktop/projects/_backups/. The optional third field is only needed when a
# project's Neon org differs from backup-all-neon.sh's default $ORG.
#
# Project ids are infrastructure identifiers that belong to the machine, not the repo, so the
# list is read from BACKUP_NEON_PROJECTS or from the per-machine file
# ${OS_BACKUP_PROJECTS_FILE:-~/.ebda-os.local.backup-projects} (same line format, '#' comments).
# Neither set: the list is empty and the dump job does nothing.
#
# A PAUSED project is left out on purpose: a nightly pg_dump restarts a paused Neon project's
# billing clock. Watch it through backup_project_paused instead (the freshness check SKIPS it).
_bp_file="${OS_BACKUP_PROJECTS_FILE:-$HOME/.ebda-os.local.backup-projects}"
if [ -z "${BACKUP_NEON_PROJECTS:-}" ] && [ -f "$_bp_file" ]; then
  BACKUP_NEON_PROJECTS="$(cat "$_bp_file")"
fi
BACKUP_NEON_PROJECTS="${BACKUP_NEON_PROJECTS:-}"

# Backup directories under _backups/ that are filled by a DIFFERENT job and must still be
# watched for staleness (space-separated). Empty by default.
BACKUP_EXTRA_DIRS="${BACKUP_EXTRA_DIRS-}"

# backup_neon_entries — one "name:project-id" per line, comments/blanks stripped.
backup_neon_entries() {
  printf '%s\n' $BACKUP_NEON_PROJECTS | while IFS= read -r _bne; do
    case "$_bne" in ''|'#'*) continue ;; esac
    printf '%s\n' "$_bne"
  done
}

# backup_watch_names — every _backups/<dir> that must hold a fresh dump: the Neon
# projects this OS dumps, plus the externally-dumped dirs. This is the checker's
# list, and it is a SUPERSET of the writer's by construction.
backup_watch_names() {
  backup_neon_entries | while IFS= read -r _bwn; do
    printf '%s\n' "${_bwn%%:*}"
  done
  printf '%s\n' ${BACKUP_EXTRA_DIRS:-} | while IFS= read -r _bwx; do
    [ -n "$_bwx" ] && printf '%s\n' "$_bwx"
  done
}

# backup_project_paused <name> — 0 when the project is parked on purpose.
#
# Both the dump job and the freshness check must consult this, or a deliberate
# pause becomes either a nightly billing wake-up or a permanent red on the OS
# health check.
backup_project_paused() {
  local _bpp="${1:-}"
  [ -n "$_bpp" ] || return 1
  [ -f "$HOME/.whisky-os-state/${_bpp}-paused" ] && return 0
  return 1
}

# backup_alert <script-dir> <title> <body...>
#
# ONE page, and the send outcome is ALWAYS reported — never swallowed to
# /dev/null. checkout-monitor learned this the hard way (2026-09-15): a
# notify.sh failure (rotated creds, curl error, file gone) was invisible at
# exactly the moment a real outage also needed paging.
#
# The body must never carry a dump's stderr: a failing neonctl/pg_dump can print
# a connection string, and this text leaves the machine. Callers pass project
# names and exit codes, and point at the local log for detail.
backup_alert() {
  local _ba_dir="$1" _ba_title="$2"; shift 2
  local _ba_body="$*"
  local _ba_notify="$_ba_dir/notify.sh" _ba_out _ba_rc
  if [ ! -x "$_ba_notify" ]; then
    echo "ALERT NOT SENT — notify.sh missing or not executable at $_ba_notify" >&2
    echo "${_ba_title}: ${_ba_body}" >&2
    return 1
  fi
  _ba_out="$("$_ba_notify" "$_ba_title" "$_ba_body" 2>&1)"; _ba_rc=$?
  if [ "$_ba_rc" -eq 0 ]; then
    echo "alert sent — $_ba_out"
  else
    echo "ALERT SEND FAILED (notify.sh exit $_ba_rc): $_ba_out" >&2
    echo "${_ba_title}: ${_ba_body}" >&2
  fi
  return "$_ba_rc"
}
