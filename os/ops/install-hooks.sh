#!/usr/bin/env bash
# install-hooks.sh — register the OS's Claude Code hooks in ~/.claude/settings.json.
#
# WHY THIS IS A SEPARATE SCRIPT: ops/install.sh copies scripts into
# ~/.claude/scripts but has never touched settings.json, so a hook could be
# shipped and never wired. That is not hypothetical — on 2026-09-04
# ops/self-eval-gate.sh had been in the repo, documented as a Stop hook, and
# registered nowhere. It had never fired. Registration is now a step with a test.
#
# Rules this obeys:
#   • MERGE, never replace. Hooks and settings the user added by hand survive.
#   • REFUSE a settings file that does not parse. Overwriting a hand-edited
#     config to "fix" it is a destructive action nobody asked for.
#   • REFUSE to register a hook whose script is missing. A registration pointing
#     at nothing is the dead-gate class this script exists to close.
#   • Idempotent: re-running adds nothing.
#
# Run AFTER ops/install.sh (which puts the scripts in place).
set -uo pipefail

DEST="$HOME/.claude/scripts"
SETTINGS="$HOME/.claude/settings.json"
mkdir -p "$(dirname "$SETTINGS")"

# event<TAB>relative-script-path — the registration table.
DESIRED="$(cat <<'TBL'
PreToolUse	hooks/block-no-verify.sh
PreToolUse	hooks/protect-config.sh
PreToolUse	hooks/block-git-add-all.sh
PreToolUse	hooks/block-root-checkout-commit.sh
PreToolUse	hooks/warn-agent-no-model.sh
PreToolUse	hooks/deny-agent-on-usage-stop.sh
PreToolUse	hooks/block-worktree-install.sh
PreToolUse	hooks/block-handoff-clobber.sh
PostToolUse	hooks/post-merge-auto-cleanup.sh
PostToolUse	hooks/post-worktree-deps.sh	900
Stop	self-eval-gate.sh
TBL
)"

DEST="$DEST" SETTINGS="$SETTINGS" DESIRED="$DESIRED" python3 <<'PY'
import json, os, sys

dest = os.environ["DEST"]
settings_path = os.environ["SETTINGS"]
# columns: event, script, [timeout seconds] - only hooks that may legitimately run long carry a timeout
desired = []
for ln in os.environ["DESIRED"].strip().split("\n"):
    if ln.strip():
        c = ln.split("\t"); desired.append((c[0], c[1], int(c[2]) if len(c) > 2 else None))

# 1. every target must exist before anything is written
missing = [rel for _, rel, _t in desired if not os.path.isfile(os.path.join(dest, rel))]
if missing:
    print("install-hooks: REFUSING — these hook scripts are not installed:", file=sys.stderr)
    for m in missing:
        print(f"  {os.path.join(dest, m)}", file=sys.stderr)
    print("  Run ops/install.sh first. Registering a hook that points at nothing\n"
          "  creates exactly the dead gate this script exists to prevent.", file=sys.stderr)
    sys.exit(1)

# 2. load, refusing to clobber anything unparseable
if os.path.exists(settings_path):
    try:
        with open(settings_path, encoding="utf-8") as fh:
            data = json.load(fh)
    except Exception as e:
        print(f"install-hooks: REFUSING — {settings_path} does not parse as JSON ({e}).\n"
              "  Left untouched. Fix it by hand; this script will not overwrite a config\n"
              "  it cannot read.", file=sys.stderr)
        sys.exit(1)
    if not isinstance(data, dict):
        print(f"install-hooks: REFUSING — {settings_path} is not a JSON object.", file=sys.stderr)
        sys.exit(1)
else:
    data = {}

hooks = data.setdefault("hooks", {})
added, already = [], []

for event, rel, tmo in desired:
    command = os.path.join(dest, rel)
    entries = hooks.setdefault(event, [])
    present = any(
        os.path.basename(str(h.get("command", ""))) == os.path.basename(command)
        for m in entries for h in (m.get("hooks") or [])
    )
    if present:
        already.append(f"{event}:{rel}")
        continue
    hook = {"type": "command", "command": command}
    if tmo: hook["timeout"] = tmo
    entries.append({"hooks": [hook]})
    added.append(f"{event}:{rel}")

# 3. atomic write — a half-written settings.json bricks every future session
tmp = settings_path + ".install-hooks.tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
os.replace(tmp, settings_path)

print(f"install-hooks: added {len(added)} ({', '.join(added) or 'none'}); "
      f"already present {len(already)} ({', '.join(already) or 'none'})")
PY
