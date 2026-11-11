#!/usr/bin/env bash
# agents/*.md is the version-controlled source of truth for ~/.claude/agents.
#  - frontmatter name == filename stem (a mismatched name silently never routes)
#  - no `| head` truncation (rule D: it hides results)
#  - ops/install-agents.sh backs up a hand-edited real file instead of overwriting it
# Run: bash ops/lib/__tests__/agents.test.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
INSTALL="$ROOT/ops/install-agents.sh"
_pass=0; _fail=0
ok() { echo "PASS: $1"; _pass=$((_pass+1)); }
no() { echo "FAIL: $1"; _fail=$((_fail+1)); }

n=0; bad=""
for f in "$ROOT"/agents/*.md; do
  n=$((n+1)); stem="$(basename "$f" .md)"
  name="$(awk 'NR==1&&$0!="---"{exit} NR>1&&$0=="---"{exit} /^name:/{sub(/^name:[ ]*/,"");print;exit}' "$f")"
  [ "$name" = "$stem" ] || bad="$bad $stem(name='$name')"
done
[ "$n" -gt 0 ] && [ -z "$bad" ] && ok "frontmatter name == filename ($n agents)" || no "frontmatter name mismatch:$bad (n=$n)"

hits="$(grep -nE '\| *head\b' "$ROOT"/agents/*.md || true)"
[ -z "$hits" ] && ok "no '| head' in any agent" || no "'| head' found: $hits"

H="$(mktemp -d)"; mkdir -p "$H/.claude/agents"
S="$(mktemp -d)"; mkdir -p "$S/agents"
printf -- '---\nname: aaa\n---\nrepo copy\n' > "$S/agents/aaa.md"
printf -- '---\nname: bbb\n---\nrepo copy\n' > "$S/agents/bbb.md"
printf -- '---\nname: ccc\n---\nrepo copy\n' > "$S/agents/ccc.md"
printf -- '---\nname: aaa\n---\nHAND EDITED\n' > "$H/.claude/agents/aaa.md"   # differs
cp "$S/agents/bbb.md" "$H/.claude/agents/bbb.md"                              # identical
# ccc absent
# Negative control: run from this worktree/feature branch it must link nothing.
G="$(HOME="$H" AGENTS_SRC="$S/agents" OS_LINK_ANY_CHECKOUT=0 bash "$INSTALL" 2>&1)"
# the same rule as ops/install-agents.sh: links only from the main checkout on main OR master (CI on a push to main IS that case;
# the old `!= master` check failed every push to main, 2026-11-11)
_br="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)"
if [ "$(git -C "$ROOT" rev-parse --absolute-git-dir)" != "$(cd "$ROOT" && cd "$(git rev-parse --git-common-dir)" && pwd)" ] || { [ "$_br" != main ] && [ "$_br" != master ]; }; then
  { printf '%s' "$G" | grep -q SKIP && [ -z "$(find "$H/.claude/agents" -type l 2>/dev/null)" ]; } && ok "refuses to link from a worktree/feature branch" || no "linked from a non-main checkout"
fi
export OS_LINK_ANY_CHECKOUT=1
HOME="$H" AGENTS_SRC="$S/agents" bash "$INSTALL" >/dev/null 2>&1 && ok "install exits 0" || no "install exits 0"
[ -L "$H/.claude/agents/aaa.md" ] && [ -L "$H/.claude/agents/bbb.md" ] && [ -L "$H/.claude/agents/ccc.md" ] && ok "all three are symlinks" || no "all three are symlinks"
grep -q 'HAND EDITED' "$H/.claude/agents/.pre-foundation-backup/aaa.md" 2>/dev/null && ok "differing real file backed up, content intact" || no "differing real file backed up, content intact"
[ ! -e "$H/.claude/agents/.pre-foundation-backup/bbb.md" ] && ok "identical file replaced without backup noise" || no "identical file replaced without backup noise"
grep -q 'repo copy' "$H/.claude/agents/aaa.md" && ok "link resolves to repo copy" || no "link resolves to repo copy"
HOME="$H" AGENTS_SRC="$S/agents" bash "$INSTALL" >/dev/null 2>&1 && [ "$(ls "$H/.claude/agents/.pre-foundation-backup" | wc -l | tr -d ' ')" = 1 ] && ok "idempotent re-run" || no "idempotent re-run"
rm -rf "$H" "$S"

echo "passed=$_pass failed=$_fail"; [ "$_fail" = 0 ]
