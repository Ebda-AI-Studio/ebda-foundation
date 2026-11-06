#!/usr/bin/env bash
# ops/force-purge-check.sh: fake HOME + fake project tree only (never the real ones). Clear tree exits 0; each hit category exits 1 and is named with a count.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; G="$ROOT/os/ops/force-purge-check.sh"
fail=0; ok() { echo "PASS: $1"; }; no() { echo "FAIL: $1"; fail=1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
H="$T/home"; P="$H/Desktop/projects"
mk() { rm -rf "$H"; mkdir -p "$H/.claude/scripts" "$H/Library/LaunchAgents" "$P/Ebda-AI-Studio/r" "$P/Whisky-11/r" "$P/Personal/r" "$P/Force-AI/x"
  echo clean > "$H/.claude/scripts/a.sh"; echo '{}' > "$H/.claude/settings.json"; echo clean > "$H/.claude/CLAUDE.md"; echo clean > "$H/AGENTS.md"; }
run() { out="$(env -u OS_PROJECTS_DIR -u OS_NONFORCE_BUSINESS_DIRS EBDA_OS_LOCAL_ENV=/nonexistent bash "$G" --home "$H" --projects "$P" 2>&1)"; rc=$?; }
mk; run; [ "$rc" = 0 ] && ok "clean tree exits 0" || { no "clean tree should exit 0"; echo "$out"; }
mk; ln -s "$P/Force-AI/gone/agent.md" "$H/.claude/agent.md"; : > "$H/Library/LaunchAgents/com.forceai.x.plist"; run
{ [ "$rc" = 1 ] && grep -q "agent.md" <<<"$out" && grep -q "com.forceai.x.plist" <<<"$out" && grep -q "symlinks (1)" <<<"$out" && grep -q "launchd-plists (1)" <<<"$out"; } && ok "dangling symlink + com.forceai plist both named, counted" || { no "symlink/plist not reported"; echo "$out"; }
mk; : > "$H/Library/LaunchAgents/com.salam.erp-backup.plist"; run
{ [ "$rc" = 1 ] && grep -q "launchd-plists (1)" <<<"$out"; } && ok "disabled com.salam.erp-backup plist is a hit" || no "salam plist missed"
mk; echo 'x force-ai-foundation y' > "$H/.claude/scripts/a.sh"; echo 'ForceAI-KW' > "$H/.claude/settings.json"; echo 'com.forceai.q' > "$H/AGENTS.md"; echo 'com.forceai.q' > "$H/Library/LaunchAgents/other.txt"; run
{ [ "$rc" = 1 ] && grep -q "scripts (1)" <<<"$out" && grep -q "settings (1)" <<<"$out" && grep -q "instructions (1)" <<<"$out" && grep -q "launchd-content (1)" <<<"$out"; } && ok "scripts/settings/instructions/launchd content hits counted" || { no "content hits missed"; echo "$out"; }
grep -q "force-ai-foundation y" <<<"$out" && no "output leaked file content" || ok "hit content is never printed"
mk; echo 'see force-ai-foundation/standard' > "$P/Whisky-11/r/README.md"; echo 'see force-ai-foundation' > "$P/Force-AI/x/ignored.md"; run
{ [ "$rc" = 1 ] && grep -q "repo-docs (1)" <<<"$out" && ! grep -q "ignored.md" <<<"$out"; } && ok "non-Force repo doc listed, Force-AI/ ignored" || { no "repo-docs wrong"; echo "$out"; }
mk; V="$P/calude code meomry"; mkdir -p "$V"; git init -q "$V"; git -C "$V" remote add origin "https://github.com/ForceAI-KW/claude-memory-vault.git"; run
{ [ "$rc" = 1 ] && grep -q "memory-vault (1)" <<<"$out"; } && ok "vault on ForceAI-KW fails" || no "vault remote missed"
git -C "$V" remote set-url origin "https://github.com/voidengineer-911/claude-memory-vault.git"; run
[ "$rc" = 0 ] && ok "vault on voidengineer-911 clears" || { no "personal vault should clear"; echo "$out"; }
mk; mkdir -p "$H/.claude/sub" "$P/Force-AI/real"; : > "$P/Force-AI/real/f"; ln -s ../../Desktop/projects/Force-AI/real/f "$H/.claude/sub/rel"; run
{ [ "$rc" = 1 ] && grep -q "symlinks (1)" <<<"$out"; } && ok "relative symlink into Force-AI/ is a hit" || { no "relative symlink missed"; echo "$out"; }
mk; mkdir -p "$P/Force-AI/real" "$H/outside"; : > "$P/Force-AI/real/f"; ln -s "$P/Force-AI/real/f" "$H/outside/hop2"; ln -s "$H/outside/hop2" "$H/outside/hop1"; ln -s "$H/outside/hop1" "$H/.claude/chain"; run
{ [ "$rc" = 1 ] && grep -q "symlinks (1)" <<<"$out" && grep -q "chain -> " <<<"$out"; } && ok "chained symlink (outside Force-AI/ until the last hop) is a hit" || { no "chained symlink missed"; echo "$out"; }
mk; ln -s "$H/AGENTS.md" "$H/.claude/safe"; run
[ "$rc" = 0 ] && ok "symlink chain that never enters Force-AI/ is clear" || { no "safe symlink flagged"; echo "$out"; }
mk; mkdir -p "$H/.claude/scripts/my dir" "$H/.claude/scripts/a:b"; echo 'ForceAI-KW' > "$H/.claude/scripts/my dir/s.sh"; echo 'ForceAI-KW' > "$H/.claude/scripts/a:b/c:d.sh"; run
{ [ "$rc" = 1 ] && grep -q "scripts (2)" <<<"$out" && grep -qF "my dir/s.sh:1" <<<"$out" && grep -qF "a:b/c:d.sh:1" <<<"$out"; } && ok "paths with spaces and ':' are reported intact with line numbers" || { no "space/colon paths mangled"; echo "$out"; }
[ "$fail" = 0 ] && echo "force-purge-check: PASS" || echo "force-purge-check: FAIL"; exit "$fail"
