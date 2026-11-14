#!/usr/bin/env bash
# validate-hooks.sh — validate ~/.claude/settings.json's hooks block.
#
# WHY: ~30 hooks run on every tool call and nothing has ever checked them. A typo
# in an event name is silently inert (Claude Code just never matches it), and a
# command pointing at a path that does not exist fails on every single tool call
# for the life of the session. Both read as "configured".
#
# The JSON Schema in schemas/hooks.schema.json is the readable contract. This
# script enforces it WITHOUT a jsonschema dependency (not guaranteed installed on
# the old Linux guests), by hand-checking exactly what the schema encodes — and then
# does the two things a schema cannot: resolve every command path, and confirm it
# is executable.
#
# Usage: ops/validate-hooks.sh [--settings <path>]
# Exit: 0 valid · 1 invalid · 2 the file is missing or unparseable (a FINDING)
set -uo pipefail
SETTINGS="$HOME/.claude/settings.json"
SCHEMA="$(cd "$(dirname "$0")/.." && pwd)/schemas/hooks.schema.json"
while [ $# -gt 0 ]; do
  case "$1" in
    --settings) SETTINGS="${2:?--settings needs a path}"; shift 2 ;;
    --schema)   SCHEMA="${2:?--schema needs a path}"; shift 2 ;;
    -h|--help)  sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "validate-hooks: unknown argument '$1'" >&2; exit 64 ;;
  esac
done

SETTINGS="$SETTINGS" SCHEMA="$SCHEMA" python3 <<'PYVAL'
import json, os, shlex, sys

sp, schema_p = os.environ["SETTINGS"], os.environ["SCHEMA"]

try:
    with open(schema_p, encoding="utf-8") as fh:
        schema = json.load(fh)
except Exception as e:
    print(f"validate-hooks: cannot read the schema at {schema_p} ({e})", file=sys.stderr)
    sys.exit(2)

EVENTS = set(schema["properties"]["hooks"]["propertyNames"]["enum"])

if not os.path.exists(sp):
    print(f"validate-hooks: {sp} does NOT exist. Every hook the OS declares is dead. "
          "This is a finding, not a clean run.", file=sys.stderr)
    sys.exit(2)
try:
    with open(sp, encoding="utf-8") as fh:
        data = json.load(fh)
except Exception as e:
    print(f"validate-hooks: {sp} does not parse ({e}). Hook state is UNKNOWN, "
          "which is not the same as valid.", file=sys.stderr)
    sys.exit(2)

errors, warnings, checked = [], [], 0
hooks = data.get("hooks")
if hooks is None:
    print(f"validate-hooks: {sp} has no `hooks` block — nothing is registered.", file=sys.stderr)
    sys.exit(1)
if not isinstance(hooks, dict):
    print("validate-hooks: `hooks` is not an object", file=sys.stderr)
    sys.exit(1)
if not hooks:
    print(f"validate-hooks: {sp} has an EMPTY `hooks` block — nothing is registered. "
          "Reporting rather than passing.", file=sys.stderr)
    sys.exit(1)

for event, groups in hooks.items():
    if event not in EVENTS:
        errors.append(f"unknown event '{event}' — Claude Code will never match it "
                      f"(known: {', '.join(sorted(EVENTS))})")
        continue
    if not isinstance(groups, list) or not groups:
        errors.append(f"{event}: value must be a non-empty array")
        continue
    for gi, group in enumerate(groups):
        if not isinstance(group, dict):
            errors.append(f"{event}[{gi}]: matcher group must be an object"); continue
        extra = set(group) - {"matcher", "hooks"}
        if extra:
            warnings.append(f"{event}[{gi}]: unrecognised key(s) {sorted(extra)}")
        if "matcher" in group and not isinstance(group["matcher"], str):
            errors.append(f"{event}[{gi}]: matcher must be a string")
        entries = group.get("hooks")
        if not isinstance(entries, list) or not entries:
            errors.append(f"{event}[{gi}]: `hooks` must be a non-empty array"); continue
        for hi, h in enumerate(entries):
            where = f"{event}[{gi}].hooks[{hi}]"
            if not isinstance(h, dict):
                errors.append(f"{where}: must be an object"); continue
            # Unrecognised keys are a WARNING, never a failure. Claude Code adds
            # hook options over time (`async` was one); a validator that fails on
            # anything it has not heard of turns every harness upgrade into a red
            # build and gets switched off. Fail only on what is provably broken.
            extra = set(h) - {"type", "command", "timeout", "async"}
            if extra:
                warnings.append(f"{where}: unrecognised key(s) {sorted(extra)} — "
                                "allowed, but not in schemas/hooks.schema.json yet")
            if h.get("type") != "command":
                errors.append(f"{where}: type must be \"command\" (got {h.get('type')!r})")
            cmd = h.get("command")
            if not isinstance(cmd, str) or not cmd.strip():
                errors.append(f"{where}: command must be a non-empty string"); continue
            checked += 1
            # what a schema cannot check: does the thing actually exist?
            try:
                argv = shlex.split(cmd)
            except ValueError:
                errors.append(f"{where}: command does not tokenise (unbalanced quotes): {cmd}")
                continue
            prog = argv[0] if argv else ""
            if prog.startswith("/") or prog.startswith("~"):
                path = os.path.expanduser(prog)
                if not os.path.exists(path):
                    errors.append(f"{where}: command path does NOT exist: {path}\n"
                                  f"      this hook fails on every tool call. Run ops/install.sh.")
                elif not os.access(path, os.X_OK):
                    errors.append(f"{where}: command exists but is NOT executable: {path}")
            else:
                warnings.append(f"{where}: command '{prog}' is resolved via PATH — a hook's PATH "
                                "under launchd is not your shell's; prefer an absolute path")

for w in warnings:
    print(f"  warn  {w}")
if errors:
    print(f"validate-hooks: {len(errors)} problem(s) in {sp}:")
    for e in errors:
        print(f"  FAIL  {e}")
    sys.exit(1)
print(f"validate-hooks: OK — {len(hooks)} event(s), {checked} hook command(s), "
      f"all paths present and executable"
      + (f", {len(warnings)} warning(s)" if warnings else ""))
PYVAL
