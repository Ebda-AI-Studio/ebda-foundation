#!/usr/bin/env bash
# --------------------------------------------------------------------
# claude-hook declaration — read by ops/dead-gate-detect.sh, which fails the
# OS self-check if a declared hook is not actually registered in
# ~/.claude/settings.json. A shipped-but-unwired hook never fires and reads
# as coverage; ops/self-eval-gate.sh sat that way until 2026-09-04.
# claude-hook: PreToolUse
# --------------------------------------------------------------------
# protect-config.sh — PreToolUse guard. Deny edits to an EXISTING gate config.
#
# WHY: the cheapest way for an agent to turn a red run green is to widen the rule
# that made it red — relax an eslint rule, loosen a tsconfig strictness flag, add
# an ignore line. The change looks like ordinary work in a diff. Creating a config
# that does not yet exist stays allowed, which is what keeps this guard tolerable:
# it only ever objects to WEAKENING something already in place.
#
# .gitignore is on the list because Auto-Company (auto-loop.sh:131-179) had to add
# a whole snapshot/restore mechanism after unattended cycles mutated theirs.
# Denying the edit is cheaper than restoring the file.
#
# stdin: Claude Code PreToolUse payload. exit 0 = allow, exit 2 = deny.
set -uo pipefail
payload="$(cat 2>/dev/null || true)"
printf '%s' "$payload" | python3 -I -c '
import fnmatch, json, os, sys

try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)

if d.get("tool_name") not in ("Edit", "Write", "NotebookEdit", "MultiEdit"):
    sys.exit(0)
path = (d.get("tool_input") or {}).get("file_path") or ""
if not path:
    sys.exit(0)

PROTECTED = [
    ".eslintrc", ".eslintrc.*", "eslint.config.*",
    ".prettierrc", ".prettierrc.*", "prettier.config.*",
    "biome.json", "biome.jsonc",
    ".ruff.toml", "ruff.toml",
    ".stylelintrc", ".stylelintrc.*",
    ".markdownlint.*", ".markdownlintrc",
    "tsconfig.json", "tsconfig.*.json",
    "vitest.config.*", "jest.config.*",
    ".gitleaks.toml", ".gitleaksignore",
    "lefthook.yml", ".pre-commit-config.yaml",
    ".gitignore",
    ".pin-actions-ignore",
]
base = os.path.basename(path)
if not any(fnmatch.fnmatch(base, p) for p in PROTECTED):
    sys.exit(0)

try:
    os.stat(path)
    exists = True
except FileNotFoundError:
    exists = False
except OSError as e:
    # Fail CLOSED. A guard that reads an unreadable path as "absent" has a hole
    # exactly where an attacker or a confused agent would push on it.
    print(f"[protect-config] Denied: cannot stat {path} ({e.strerror}). "
          "Failing closed rather than assuming the file is absent.", file=sys.stderr)
    sys.exit(2)

if not exists:
    sys.exit(0)  # creating a config is fine; weakening one is not

print(f"[protect-config] Denied: editing an existing gate config — {path}\n"
      "  Weakening a gate to make a run pass is the failure this blocks. Fix the code\n"
      "  the gate is objecting to. If the config itself is genuinely wrong, change it in\n"
      "  a separate commit that says so and is reviewed on its own merits.\n"
      "  (standard/agent-containment.md)", file=sys.stderr)
sys.exit(2)
'
