#!/usr/bin/env bash
# Whisky AI OS — teardown. Stops + unloads every OS job on THIS machine.
#
# Use on the OLD (personal) Mac after the OS has moved to the the Ebda Studio Mac, so
# this machine becomes a pure controller (SSH into the Studio) and stops running
# the automations itself.
#
#   uninstall.sh              stop + unload all ${OS_LAUNCHD_PREFIX}.* jobs (reversible: re-run install.sh)
#   uninstall.sh --purge      also DELETE the plists + ~/.claude/scripts runtime copies
#   uninstall.sh --dry-run    show what would happen, change nothing
#
# NEVER touches ops/ source, memory, the vault, or ~/.whisky-services.env — only
# the local launchd jobs (+ runtime copies with --purge). Fully reversible via install.sh.
# shellcheck source=lib/os-config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/os-config.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-config.sh" 2>/dev/null || true
command -v os_config_load >/dev/null 2>&1 && os_config_load
set -uo pipefail
PURGE=0; DRY=0
for a in "$@"; do case "$a" in --purge) PURGE=1;; --dry-run) DRY=1;; esac; done
U=$(id -u)
LA="$HOME/Library/LaunchAgents"

jobs=$(ls "$LA/"${OS_LAUNCHD_PREFIX}.*.plist 2>/dev/null | wc -l | tr -d ' ')
echo "OS jobs on this machine: $jobs"
[ "$DRY" = 1 ] && echo "(dry-run — nothing will change)"

for plist in "$LA/"${OS_LAUNCHD_PREFIX}.*.plist; do
  [ -f "$plist" ] || continue
  label=$(basename "$plist" .plist)
  if [ "$DRY" = 1 ]; then
    echo "  would stop+unload $label$( [ "$PURGE" = 1 ] && echo ' + delete plist')"
    continue
  fi
  launchctl bootout "gui/$U/$label" 2>/dev/null || true
  echo "  stopped $label"
  [ "$PURGE" = 1 ] && rm -f "$plist"
done

# Deregister the OS's Claude Code hooks. install-hooks.sh writes registrations into
# ~/.claude/settings.json; without this, uninstalling leaves entries pointing at
# scripts that are gone — every session then fails those hooks on every tool call.
# Only OUR entries are removed (matched by path under ~/.claude/scripts); anything
# the user registered by hand survives, and an unparseable settings file is refused.
if [ "$DRY" = 1 ]; then
  echo "  would deregister OS hooks from ~/.claude/settings.json"
else
  python3 - <<'PY2' || echo "  WARN: could not deregister hooks (settings.json left untouched)"
import json, os, sys
sp = os.path.join(os.environ["HOME"], ".claude", "settings.json")
if not os.path.exists(sp):
    sys.exit(0)
try:
    with open(sp, encoding="utf-8") as fh:
        d = json.load(fh)
except Exception:
    print("  settings.json does not parse — refusing to edit it", file=sys.stderr)
    sys.exit(1)
ours = os.path.join(os.environ["HOME"], ".claude", "scripts")
removed = 0
for event, arr in list((d.get("hooks") or {}).items()):
    keep_matchers = []
    for m in arr:
        kept = []
        for h in (m.get("hooks") or []):
            cmd = str(h.get("command", ""))
            first = cmd.split()[0] if cmd.split() else ""
            if first.startswith(ours):
                removed += 1
            else:
                kept.append(h)
        if kept:
            m["hooks"] = kept
            keep_matchers.append(m)
    if keep_matchers:
        d["hooks"][event] = keep_matchers
    else:
        del d["hooks"][event]
tmp = sp + ".uninstall.tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(d, fh, indent=2); fh.write("\n")
os.replace(tmp, sp)
print(f"  deregistered {removed} OS hook(s) from settings.json")
PY2
fi

if [ "$PURGE" = 1 ] && [ "$DRY" = 0 ]; then
  # remove installed runtime copies (source in ops/ is untouched)
  rm -rf "$HOME/.claude/scripts/dashboard" 2>/dev/null || true
  echo "purged plists + ~/.claude/scripts/dashboard. Scripts under ~/.claude/scripts left in place (harmless; delete manually if desired)."
  echo "NOTE: ~/.whisky-services.env, memory, and the vault are NOT touched."
fi
echo "done. This machine no longer runs the OS jobs. Re-enable anytime: ops/install.sh"
