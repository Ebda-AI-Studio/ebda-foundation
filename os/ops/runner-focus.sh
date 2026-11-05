#!/usr/bin/env bash
# Whisky AI OS — runner-focus: run ONLY the CI runners that are needed right now.
#
# WHY (Ahmad 2026-10-08): the Umbra guest fwb-ci6 (6 CPU / 6 GiB) ran 22 GitHub
# runner services for ~19 repos, all the time. Idle runners cost RAM, and the guest
# hung twice in one day under load. "Only activate what is using CI, the rest
# deactivated, so the full RAM goes to the repo that needs CI."
#
#   runner-focus.sh on  <slug>...   start + enable those repos' runner units
#   runner-focus.sh off <slug>...   stop + disable them (a BUSY runner is never stopped)
#   runner-focus.sh only <slug>...  focus = exactly these; everything else off
#   runner-focus.sh all             re-enable every runner and drop the focus file
#   runner-focus.sh auto            turn ON non-focused repos that have a job QUEUED
#                                   for a self-hosted runner (the guard calls this)
#   runner-focus.sh status          active set, idle/busy, guest memory
#   runner-focus.sh regex           (internal) ERE matching the focused units; the
#                                   guard and runner-reregister.sh use it so a
#                                   deactivated runner is EXPECTED to be down
#
# A <slug> is the repo part of the runner name (fwb-ci6-<slug>-<n> / umbra-<slug>-<n>).
# State: $RUNNER_FOCUS_FILE (default ~/.umbra/runner-focus.json) = {"focus":[slugs]}.
# No file = no focus = every runner is expected (the pre-2026-10-08 behaviour).
# The VM disk stays on the external SSD (~/.umbra/machines -> /Volumes/umbra); this
# script never touches it.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/lib/os-state.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-state.sh" 2>/dev/null || true

GUEST="${RUNNER_UMBRA_MACHINE:-fwb-ci6}"
FOCUS_FILE="${RUNNER_FOCUS_FILE:-$HOME/.umbra/runner-focus.json}"
KNOWN_OWNERS="${RUNNER_OWNERS:-Ebda-AI-Studio Whisky-11 voidengineer-911}"
UT="${RUNNER_FOCUS_TIMEOUT:-60}"
QUEUE_MIN="${RUNNER_FOCUS_QUEUE_MIN:-3}"   # a job queued longer than this is "waiting"

_t() { if command -v _ut >/dev/null 2>&1; then _ut "$UT" "$@"; else "$@"; fi; }
gx() { _t umbra exec "$GUEST" -- "$1"; }
die() { echo "runner-focus: $*" >&2; exit 2; }
# Starting runner listeners costs memory (each unit peaks ~1 GB while it starts). 2026-10-25 16:51: a focus change was
# applied while the 5 GiB guest was already thrashing; the guest OOM-killed running Workers ("Abandoned" jobs). So:
# refuse to START runners when the guest has < RUNNER_FOCUS_MIN_AVAIL_MB (500) available (0 disables), re-check before
# every start, and pause RUNNER_FOCUS_STAGGER_SEC (3) between starts so they never arrive as a wave. Stopping is free.
guest_avail_mb() { gx "awk '/^MemAvailable:/{print int(\$2/1024)}' /proc/meminfo" 2>/dev/null | tr -dc '0-9'; }
mem_ok() {
  local min="${RUNNER_FOCUS_MIN_AVAIL_MB:-500}" a
  [ "$min" -gt 0 ] || return 0
  a="$(guest_avail_mb)"
  [ -n "$a" ] && [ "$a" -ge "$min" ]   # unreadable = not ok: we will not start runners blind
}
start_unit() { # prints "on"/"FAIL"/"DEFER"; returns 0 only when started
  local u="$1"
  if ! mem_ok; then echo "  DEFER $u (guest memory low or unreadable; < ${RUNNER_FOCUS_MIN_AVAIL_MB:-500} MB available)"; return 2; fi
  if gx "sudo -n systemctl enable --now $u" >/dev/null 2>&1; then echo "  on   $u"; sleep "${RUNNER_FOCUS_STAGGER_SEC:-3}"; return 0; fi
  echo "  FAIL $u"; return 1
}
valid_slug() { printf '%s' "$1" | grep -qE '^[A-Za-z0-9_-]+$'; }

# ── state file ───────────────────────────────────────────────────────────────
focus_exists() { [ -f "$FOCUS_FILE" ]; }
focus_read() {   # prints slugs one per line; rc 1 = file unreadable/invalid
  python3 -c '
import json,sys
d=json.load(open(sys.argv[1])); f=d["focus"]
assert isinstance(f,list) and all(isinstance(x,str) for x in f)
print("\n".join(f))' "$FOCUS_FILE" 2>/dev/null
}
focus_write() {  # slugs as args
  mkdir -p "$(dirname "$FOCUS_FILE")"
  python3 -c '
import json,sys,datetime
f=sorted(set(sys.argv[2:]))
json.dump({"focus":f,"updated":datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")},open(sys.argv[1]+".tmp","w"),indent=1)
' "$FOCUS_FILE" "$@" && mv "$FOCUS_FILE.tmp" "$FOCUS_FILE"
}

# ── unit helpers. Unit: actions.runner.<scope>.<runner>.service ──────────────
#   scope  = <owner>-<repo> (repo-level) or <owner> (org-level)
#   runner = <machine>-<slug>-<n> | umbra-<slug>-<n>
# list-unit-files, NOT list-units: a stopped+disabled unit is unloaded and vanishes from list-units.
all_units() { gx 'systemctl list-unit-files "actions.runner.*" --no-legend --plain | awk "{print \$1}" | sort -u'; }
unit_slug() {
  local m r; m="${1#actions.runner.}"; m="${m%.service}"; r="${m#*.}"
  case "$r" in "$GUEST"-*) r="${r#"$GUEST"-}" ;; umbra-*) r="${r#umbra-}" ;; esac
  printf '%s' "${r%-[0-9]*}"
}
unit_runner() { local m; m="${1#actions.runner.}"; m="${m%.service}"; printf '%s' "${m#*.}"; }
# → "repos/<o>/<r>" or "orgs/<o>"
unit_api() {
  local m scope k; m="${1#actions.runner.}"; scope="${m%%.*}"
  for k in $KNOWN_OWNERS; do
    [ "$scope" = "$k" ] && { printf 'orgs/%s' "$k"; return; }
    case "$scope" in "$k"-*) printf 'repos/%s/%s' "$k" "${scope#"$k"-}"; return ;; esac
  done
}
# idle | busy | unknown (unknown = GitHub cannot say; callers treat it as busy)
unit_busy() {
  local api runner b; api="$(unit_api "$1")"; runner="$(unit_runner "$1")"
  [ -n "$api" ] || { echo unknown; return; }
  b="$(_t gh api "$api/actions/runners" --paginate \
        --jq ".runners[] | select(.name==\"$runner\") | .busy" 2>/dev/null | head -1)"
  case "$b" in true) echo busy ;; false) echo idle ;; *) echo unknown ;; esac
}

# ERE over unit names for a slug list (empty arg list = matches nothing)
focus_regex() {
  local alt=""; for s in "$@"; do alt="${alt:+$alt|}$s"; done
  [ -n "$alt" ] || { printf '^$'; return; }
  printf '\\.(%s|umbra)-(%s)-[0-9]+\\.service$' "$GUEST" "$alt"
}

units_of() {   # <slug> → matching units (stdin: unit list)
  local re; re="$(focus_regex "$1")"; grep -E "$re" || true
}

# ── commands ─────────────────────────────────────────────────────────────────
do_on() {
  local units s u cur=() ok=0 bad=0
  units="$(all_units)"; [ -n "$units" ] || die "cannot read runner units on $GUEST (VM down?)"
  for s in "$@"; do
    valid_slug "$s" || die "bad slug '$s'"
    [ -n "$(printf '%s\n' "$units" | units_of "$s")" ] || die "no runner units for slug '$s'"
  done
  for s in "$@"; do
    for u in $(printf '%s\n' "$units" | units_of "$s"); do
      start_unit "$u"; case $? in 0) ok=$((ok+1)) ;; *) bad=$((bad+1)) ;; esac
    done
  done
  # no focus file = every runner is already expected; `on` must not create one
  focus_exists || { echo "runner-focus on: $ok started, $bad failed (no focus file — nothing to record)"; [ "$bad" -eq 0 ]; return; }
  cur=($(focus_read)) || die "focus file unreadable: $FOCUS_FILE"
  [ "$bad" -eq 0 ] && focus_write ${cur[@]+"${cur[@]}"} "$@"
  echo "runner-focus on: $ok started, $bad failed"; [ "$bad" -eq 0 ]
}

# off: never stop a BUSY (or unknowable) runner; its slug stays in the focus file
# until a later `off` succeeds, so the file always says what is really running.
do_off() {
  local units s u cur=() done_s=() keep=() skipped=0 off=0 bad=0 b clean c
  units="$(all_units)"; [ -n "$units" ] || die "cannot read runner units on $GUEST (VM down?)"
  if focus_exists; then cur=($(focus_read)) || die "focus file unreadable: $FOCUS_FILE"
  else cur=($(printf '%s\n' "$units" | while read -r u; do [ -n "$u" ] && unit_slug "$u"; echo; done | sort -u | grep -v '^$')); fi
  for s in "$@"; do
    valid_slug "$s" || die "bad slug '$s'"
    [ -n "$(printf '%s\n' "$units" | units_of "$s")" ] || die "no runner units for slug '$s'"
  done
  for s in "$@"; do
    clean=1
    for u in $(printf '%s\n' "$units" | units_of "$s"); do
      b="$(unit_busy "$u")"
      if [ "$b" != idle ]; then echo "  SKIP $u — $b (rerun 'off $s' when idle)"; skipped=$((skipped+1)); clean=0; continue; fi
      if gx "sudo -n systemctl disable --now $u" >/dev/null 2>&1; then off=$((off+1)); echo "  off  $u"
      else bad=$((bad+1)); clean=0; echo "  FAIL $u"; fi
    done
    [ "$clean" -eq 1 ] && done_s+=("$s")
  done
  # focus = what is meant to be running: drop only the slugs fully stopped
  for c in ${cur[@]+"${cur[@]}"}; do
    case " ${done_s[*]-} " in *" $c "*) ;; *) keep+=("$c") ;; esac
  done
  focus_write ${keep[@]+"${keep[@]}"}
  echo "runner-focus off: $off stopped, $skipped skipped (busy/unknown), $bad failed"; [ "$bad" -eq 0 ]
}

do_only() {
  local units all s want_off=() want_on=("$@")
  [ "$#" -ge 1 ] || die "only needs at least one slug (use 'all' to re-enable everything)"
  units="$(all_units)"; [ -n "$units" ] || die "cannot read runner units on $GUEST (VM down?)"
  all="$(printf '%s\n' "$units" | while read -r u; do [ -n "$u" ] && unit_slug "$u"; echo; done | sort -u | grep -v '^$')"
  for s in "$@"; do printf '%s\n' "$all" | grep -qx "$s" || die "no runner units for slug '$s'"; done
  for s in $all; do case " $* " in *" $s "*) ;; *) want_off+=("$s") ;; esac; done
  do_on "${want_on[@]}" || return 1
  [ ${#want_off[@]} -eq 0 ] || do_off ${want_off[@]+"${want_off[@]}"}
}

do_all() {
  local units u
  units="$(all_units)"; [ -n "$units" ] || die "cannot read runner units on $GUEST (VM down?)"
  local deferred=0
  for u in $units; do start_unit "$u" || deferred=$((deferred+1)); done
  # keep the focus file while anything was deferred/failed: the fleet is NOT back to "every runner expected" yet
  if [ "$deferred" -gt 0 ]; then echo "runner-focus all: $deferred runner(s) not started (memory/failure); focus file kept, re-run later"; return 1; fi
  rm -f "$FOCUS_FILE"; echo "runner-focus all: focus file removed — every runner expected again"
}

# auto: a non-focused REPO-level runner with a job queued for a self-hosted runner
# (labels umbra-ci / self-hosted) for > QUEUE_MIN minutes is turned ON. Org-level
# runners (ebda) are never auto-handled: they are always in the focus set.
do_auto() {
  focus_exists || { echo "runner-focus auto: no focus file — all runners are on, nothing to do"; return 0; }
  local cur units u s api seen="" now run job n=0
  cur=($(focus_read)) || die "focus file unreadable: $FOCUS_FILE"
  units="$(all_units)"; [ -n "$units" ] || return 0
  now="$(date -u +%s)"
  for u in $units; do
    s="$(unit_slug "$u")"; api="$(unit_api "$u")"
    case " ${cur[*]-} $seen " in *" $s "*) continue ;; esac
    case "$api" in repos/*) ;; *) continue ;; esac
    seen="$seen $s"
    for run in $(_t gh api "$api/actions/runs?status=queued&per_page=5" --jq '.workflow_runs[].id' 2>/dev/null); do
      job="$(_t gh api "$api/actions/runs/$run/jobs" --jq \
        "[.jobs[] | select(.status==\"queued\" and ((.labels|index(\"umbra-ci\")) or (.labels|index(\"self-hosted\")))) | .created_at] | first // empty" 2>/dev/null)"
      [ -n "$job" ] || continue
      if [ $(( now - $(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$job" +%s 2>/dev/null || date -u -d "$job" +%s 2>/dev/null || echo "$now") )) -ge $((QUEUE_MIN*60)) ]; then
        echo "runner-focus auto: $s has a job queued for a self-hosted runner since $job — turning it ON"
        do_on "$s" && n=$((n+1)); break
      fi
    done
  done
  echo "runner-focus auto: activated $n repo(s)"
}

do_status() {
  local units u s st en b act=0 tot=0 f
  units="$(all_units)"; [ -n "$units" ] || die "cannot read runner units on $GUEST (VM down?)"
  if focus_exists; then f="$(focus_read | tr '\n' ' ')" || f="UNREADABLE"; else f="(no focus file: all runners expected)"; fi
  echo "focus: $f"
  printf '%-34s %-9s %-9s %s\n' RUNNER STATE ENABLED GITHUB
  local rows; rows="$(gx 'for u in $(systemctl list-unit-files "actions.runner.*" --no-legend --plain | awk "{print \$1}" | sort -u); do echo "$u $(systemctl is-active $u) $(systemctl is-enabled $u)"; done')"
  while read -r u st en; do
    [ -n "$u" ] || continue
    b="-"; if [ "$st" = active ]; then b="$(unit_busy "$u")"; act=$((act+1)); fi
    tot=$((tot+1)); printf '%-34s %-9s %-9s %s\n' "$(unit_runner "$u")" "${st:-?}" "${en:-?}" "$b"
  done <<< "$rows"
  echo "active: $act/$tot"
  echo "guest memory (MiB):"; gx 'free -m | sed -n 1,2p'
}

cmd="${1:-}"; [ "$#" -gt 0 ] && shift
case "$cmd" in
  on)     [ "$#" -ge 1 ] || die "usage: on <slug>..."; do_on "$@" ;;
  off)    [ "$#" -ge 1 ] || die "usage: off <slug>..."; do_off "$@" ;;
  only)   do_only "$@" ;;
  all)    do_all ;;
  auto)   do_auto ;;
  status) do_status ;;
  regex)  # exit 3 = focus file present but unreadable (callers must NOT heal)
          focus_exists || exit 4            # exit 4 = no focus (everything expected)
          s=($(focus_read)) || exit 3
          focus_regex ${s[@]+"${s[@]}"} ;;
  *)      sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
