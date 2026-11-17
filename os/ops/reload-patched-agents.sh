#!/usr/bin/env bash
#
# reload-patched-agents.sh — reload the launchd agents whose PATH was patched.
#
# A plist edit changes NOTHING until the agent is reloaded — launchd holds the
# EnvironmentVariables it read at load time. Editing 42 files and stopping there
# is the "merged is not deployed" trap in its purest form.
#
# Staggered because 15 of the 42 have RunAtLoad=true and would otherwise all
# fire at once: a burst of gh/Sentry/Cloudflare API calls and a wall of Telegram
# alerts.
#
# Verifies every agent is loaded AFTER the reload. An unload that fails to
# re-load leaves a monitor silently OFF, which is strictly worse than the dead
# gate this fix exists to close.

set -uo pipefail
LA="$HOME/Library/LaunchAgents"
LOG="$HOME/Library/Logs/reload-patched-agents.log"
STAGGER="${STAGGER:-4}"

echo "=== $(date '+%Y-%m-%dT%H:%M:%S') reload start ===" >>"$LOG"

# Only agents that carry a PATH env — i.e. exactly the set fix-launchd-path.sh
# touched. Read from disk rather than a hardcoded list so the two can't drift.
#
# NOT `mapfile`: macOS ships bash 3.2 as /bin/bash and mapfile arrived in bash
# 4. The first version of this script used it, died with "command not found",
# and under `set -u` exited on the next line — which, by luck rather than
# design, was before the first unload. Same class as the dead gate this whole
# change is about: assuming a binary/builtin is present because it is present
# somewhere else.
AGENTS=()
while IFS= read -r line; do
  [ -n "$line" ] && AGENTS+=("$line")
done < <(python3 - "$LA" <<'PY'
import plistlib, glob, os, sys
for p in sorted(glob.glob(os.path.join(sys.argv[1], "*.plist"))):
    try: d = plistlib.load(open(p, "rb"))
    except Exception: continue
    if "PATH" in d.get("EnvironmentVariables", {}):
        print(d.get("Label") or os.path.basename(p)[:-6])
PY
)

# Snapshot what launchd currently has loaded. An agent that is deliberately
# unloaded (parked service, retired watcher) must STAY unloaded — reloading it
# would silently restart something Ahmad turned off, and "pausing a service
# needs every waker" is a lesson already paid for once.
LOADED_NOW="$(launchctl list | awk '{print $3}')"

ok=0; skipped=0; failed=()
# REAL BUG, found by ops/lib/__tests__/empty-array-guard.test.sh when this script was
# adopted into the repo: AGENTS starts empty and only grows conditionally, so a run that
# finds no patched agents reached a bare expansion of an empty array and died on bash 3.2
# (macOS /bin/bash, 3.2.57) with "AGENTS[@]: unbound variable" under `set -u` — precisely
# the no-op case this script should handle quietly.
for label in ${AGENTS[@]+"${AGENTS[@]}"}; do
  plist="$LA/$label.plist"
  [ -f "$plist" ] || { echo "  no plist for $label" >>"$LOG"; failed+=("$label:noplist"); continue; }
  if ! grep -qxF "$label" < <(printf '%s\n' "$LOADED_NOW"); then
    skipped=$((skipped+1)); echo "  skipped (was not loaded) $label" >>"$LOG"; continue
  fi
  launchctl unload "$plist" 2>/dev/null
  if launchctl load -w "$plist" 2>>"$LOG"; then
    # `load` returning 0 is not proof: confirm it is actually in the list.
    # Retry briefly — `load -w` returns before launchd has necessarily published
    # the label, and a single immediate check reported 13 of 28 healthy reloads
    # as "not-listed" when all 13 were in fact loaded. A verifier that cries
    # wolf gets ignored, which is worse than not having one.
    listed=no
    for _try in 1 2 3 4 5; do
      if grep -qF "$label" < <(launchctl list); then listed=yes; break; fi
      sleep 1
    done
    if [ "$listed" = yes ]; then
      ok=$((ok+1)); echo "  reloaded $label" >>"$LOG"
    else
      failed+=("$label:not-listed"); echo "  NOT LISTED after load: $label" >>"$LOG"
    fi
  else
    failed+=("$label:load-failed"); echo "  LOAD FAILED: $label" >>"$LOG"
  fi
  sleep "$STAGGER"
done

echo "reloaded=$ok skipped=$skipped failed=${#failed[@]} ${failed[*]:-}" >>"$LOG"
printf 'reloaded=%s skipped(not-loaded)=%s failed=%s %s\n' "$ok" "$skipped" "${#failed[@]}" "${failed[*]:-}"
