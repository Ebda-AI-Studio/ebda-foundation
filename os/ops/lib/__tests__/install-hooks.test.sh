#!/usr/bin/env bash
# install-hooks.sh must MERGE into ~/.claude/settings.json, never clobber it,
# never duplicate on re-run, and refuse to register a hook whose script is absent
# (registering a missing target creates the dead-gate class this closes).
# Run: bash ops/lib/__tests__/install-hooks.test.sh
set -uo pipefail
SCRIPT="$(cd "$(dirname "$0")/../.." && pwd)/install-hooks.sh"
_pass=0; _fail=0
ok() { echo "PASS: $1"; _pass=$((_pass+1)); }
no() { echo "FAIL: $1"; _fail=$((_fail+1)); }

new_home() {
  local h; h="$(mktemp -d)"
  mkdir -p "$h/.claude/scripts/hooks"
  for f in hooks/block-no-verify.sh hooks/protect-config.sh hooks/block-git-add-all.sh hooks/block-root-checkout-commit.sh hooks/warn-agent-no-model.sh hooks/deny-agent-on-usage-stop.sh hooks/post-merge-auto-cleanup.sh hooks/block-worktree-install.sh hooks/block-handoff-clobber.sh hooks/block-stash-pop.sh hooks/post-worktree-deps.sh self-eval-gate.sh; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$h/.claude/scripts/$f"; chmod +x "$h/.claude/scripts/$f"
  done
  printf '%s' "$h"
}

H="$(new_home)"
cat > "$H/.claude/settings.json" <<'JSON'
{"theme":"dark","hooks":{"Stop":[{"hooks":[{"type":"command","command":"/pre/existing.sh"}]}]}}
JSON

HOME="$H" bash "$SCRIPT" >/dev/null 2>&1 && ok "exits 0 on a valid settings file" || no "exits 0 on a valid settings file"

python3 - "$H/.claude/settings.json" <<'PY' && ok "registers all three, keeps existing" || no "registers all three, keeps existing"
import json,sys
d=json.load(open(sys.argv[1]))
cmds=[h["command"] for arr in d["hooks"].values() for m in arr for h in m.get("hooks",[])]
assert d.get("theme")=="dark", "clobbered unrelated top-level settings"
assert any("existing.sh" in c for c in cmds), "clobbered a pre-existing hook"
for want in ("block-no-verify.sh","protect-config.sh","block-git-add-all.sh","block-root-checkout-commit.sh","warn-agent-no-model.sh","deny-agent-on-usage-stop.sh","post-merge-auto-cleanup.sh","block-worktree-install.sh","post-worktree-deps.sh","self-eval-gate.sh"):
    assert any(want in c for c in cmds), f"{want} not registered"
PY

# the two guards must be on PreToolUse and self-eval-gate on Stop
python3 - "$H/.claude/settings.json" <<'PY' && ok "registered on the correct events" || no "registered on the correct events"
import json,sys
d=json.load(open(sys.argv[1]))
def ev_of(name):
    return [e for e,arr in d["hooks"].items() for m in arr for h in m.get("hooks",[]) if name in h["command"]]
assert ev_of("block-no-verify.sh")==["PreToolUse"], ev_of("block-no-verify.sh")
assert ev_of("protect-config.sh")==["PreToolUse"], ev_of("protect-config.sh")
for g in ("block-git-add-all.sh","block-root-checkout-commit.sh","warn-agent-no-model.sh"):
    assert ev_of(g)==["PreToolUse"], (g, ev_of(g))
assert ev_of("post-merge-auto-cleanup.sh")==["PostToolUse"], ev_of("post-merge-auto-cleanup.sh")
assert ev_of("block-worktree-install.sh")==["PreToolUse"], ev_of("block-worktree-install.sh")
assert ev_of("post-worktree-deps.sh")==["PostToolUse"], ev_of("post-worktree-deps.sh")
assert [h.get("timeout") for arr in d["hooks"].values() for m in arr for h in m["hooks"] if "post-worktree-deps.sh" in h["command"]]==[900], "long-running hook lost its timeout"
assert ev_of("self-eval-gate.sh")==["Stop"], ev_of("self-eval-gate.sh")
PY

# idempotent
HOME="$H" bash "$SCRIPT" >/dev/null 2>&1
n=$(python3 -c "
import json;d=json.load(open('$H/.claude/settings.json'))
print(sum(1 for arr in d['hooks'].values() for m in arr for h in m.get('hooks',[]) if 'block-no-verify.sh' in h['command']))")
[ "$n" = "1" ] && ok "idempotent (no duplicate registration)" || no "idempotent (got $n)"

# malformed settings must NOT be overwritten
echo 'not json' > "$H/.claude/settings.json"
HOME="$H" bash "$SCRIPT" >/dev/null 2>&1 && no "refuses malformed settings" || ok "refuses malformed settings"
grep -q 'not json' "$H/.claude/settings.json" && ok "malformed settings left intact" || no "malformed settings left intact"
rm -rf "$H"

# a missing hook script must be REFUSED, not registered as a dead gate
H2="$(new_home)"; rm -f "$H2/.claude/scripts/hooks/protect-config.sh"
echo '{}' > "$H2/.claude/settings.json"
HOME="$H2" bash "$SCRIPT" >/dev/null 2>&1 && no "refuses to register a missing hook script" || ok "refuses to register a missing hook script"
grep -q 'protect-config' "$H2/.claude/settings.json" && no "missing hook was not written" || ok "missing hook was not written"
rm -rf "$H2"

# absent settings file: create it rather than failing
H3="$(new_home)"
HOME="$H3" bash "$SCRIPT" >/dev/null 2>&1 && ok "creates settings.json when absent" || no "creates settings.json when absent"
[ -f "$H3/.claude/settings.json" ] && ok "settings.json exists after run" || no "settings.json exists after run"
rm -rf "$H3"

echo; echo "install-hooks: $_pass passed, $_fail failed"
[ "$_fail" -eq 0 ]
