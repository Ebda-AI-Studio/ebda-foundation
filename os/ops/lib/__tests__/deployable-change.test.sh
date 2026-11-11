#!/usr/bin/env bash
# Test deployable_verdict: inert vs deployable, and every uncertain case
# falling to "unknown" (which callers must treat as deployable).
set -uo pipefail
. "$(dirname "$0")/../deployable-change.sh"
_pass=0; _fail=0
eq() { if [ "$2" = "$3" ]; then echo "PASS: $1"; _pass=$((_pass+1)); else echo "FAIL: $1 — got '$2' want '$3'"; _fail=$((_fail+1)); fi; }
v()  { printf '%s\n' "$@" | deployable_verdict; }

# ── the real 2026-08-25 case: whatsapp #158, CI-only ──────────────────────────────
eq "the whatsapp drift delta is inert" \
   "$(v .github/workflows/db-backup.yml .github/workflows/rls-proof.yml .github/workflows/semgrep.yml)" \
   "none"

# ── inert paths ──────────────────────────────────────────────────────────────
eq "workflows are inert"   "$(v .github/workflows/ci.yml)"        "none"
eq "docs are inert"        "$(v docs/architecture.md)"            "none"
eq "root README is inert"  "$(v README.md)"                       "none"
eq "nested md is inert"    "$(v apps/api/NOTES.md)"               "none"
eq "editor cfg is inert"   "$(v .vscode/settings.json)"           "none"
eq "gitignore is inert"    "$(v .gitignore)"                      "none"
eq "LICENSE is inert"      "$(v LICENSE)"                         "none"
eq "CODEOWNERS is inert"   "$(v CODEOWNERS)"                      "none"

# ── deployable paths ─────────────────────────────────────────────────────────
eq "source is deployable"       "$(v src/index.ts)"               "deployable"
eq "package.json is deployable" "$(v package.json)"               "deployable"
eq "lockfile is deployable"     "$(v pnpm-lock.yaml)"             "deployable"
eq "Dockerfile is deployable"   "$(v Dockerfile)"                 "deployable"
eq "migration is deployable"    "$(v prisma/migrations/x/migration.sql)" "deployable"
eq "env example is deployable"  "$(v .env.example)"               "deployable"

# ONE deployable file among many inert ones must win. This is the direction
# that matters: a mixed commit is a real deploy.
eq "one deployable file wins" \
   "$(v .github/workflows/ci.yml docs/a.md src/server.ts README.md)" "deployable"
eq "order does not matter" \
   "$(v src/server.ts .github/workflows/ci.yml)"                  "deployable"

# ── uncertainty must NOT read as inert ───────────────────────────────────────
# An empty list almost always means the API call failed. Reading that as "none"
# would silence a real drift alert — the exact failure this whole change is
# meant to avoid creating.
eq "empty input is unknown"        "$(printf '' | deployable_verdict)"       "unknown"
eq "blank lines only are unknown"  "$(printf '\n\n' | deployable_verdict)"   "unknown"
# GitHub caps compare .files at 300; a capped list cannot prove its tail inert.
eq "truncation is unknown"         "$(v .github/workflows/ci.yml __TRUNCATED__)" "unknown"
eq "truncation beats inert prefix" "$(v docs/a.md docs/b.md __TRUNCATED__)"  "unknown"
# ...but a deployable file seen BEFORE the marker is already decisive.
eq "deployable before truncation still deployable" \
   "$(v src/a.ts __TRUNCATED__)"                                  "deployable"

# ── paths that LOOK inert but are not ────────────────────────────────────────
# Substring traps: a file merely containing "docs" or ".github" in its name is
# not in those directories.
eq "docs-like filename is deployable"    "$(v src/docs-loader.ts)"        "deployable"
eq "md-like filename is deployable"      "$(v src/markdown.ts)"           "deployable"
eq "github-like dir is deployable"       "$(v src/github/client.ts)"      "deployable"
eq "app named docs/ nested is deployable" "$(v apps/web/src/docs/page.tsx)" "deployable"

echo; echo "$_pass passed, $_fail failed"; [ "$_fail" -eq 0 ]
