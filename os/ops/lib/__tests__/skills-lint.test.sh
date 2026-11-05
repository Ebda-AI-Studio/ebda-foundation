#!/usr/bin/env bash
# skills/*/SKILL.md must be well-formed (frontmatter name == dir, description <= 1024
# chars, file <= 200 lines) and install.sh's skill-link step must SYMLINK, skip
# force-audit by default, and refuse to clobber a real directory.
# The link step is extracted from install.sh and run alone under a temp HOME: running
# the whole installer would bootstrap real launchd jobs.
# Run: bash ops/lib/__tests__/skills-lint.test.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
_pass=0; _fail=0
ok() { echo "PASS: $1"; _pass=$((_pass+1)); }
no() { echo "FAIL: $1"; _fail=$((_fail+1)); }

n=0
for f in "$ROOT"/skills/*/SKILL.md; do
  [ -f "$f" ] || continue; n=$((n+1))
  dir="$(basename "$(dirname "$f")")"
  res="$(python3 - "$f" "$dir" <<'PY'
import sys,re
t=open(sys.argv[1],encoding="utf-8").read(); d=sys.argv[2]
m=re.match(r"---\n(.*?)\n---\n",t,re.S)
if not m: print("no frontmatter"); sys.exit()
fm=m.group(1)
nm=re.search(r"^name:\s*(.+)$",fm,re.M); ds=re.search(r"^description:\s*(.+)$",fm,re.M)
if not nm or nm.group(1).strip().strip("\"'")!=d: print("name != dir"); sys.exit()
if not ds: print("no description"); sys.exit()
if len(ds.group(1).strip().strip("\"'"))>1024: print("description > 1024"); sys.exit()
if t.count("\n")>200: print("> 200 lines"); sys.exit()
print("ok")
PY
)"
  [ "$res" = "ok" ] && ok "skills/$dir/SKILL.md well-formed" || no "skills/$dir/SKILL.md: $res"
done
[ "$n" -gt 0 ] && ok "found $n skill(s)" || no "no skills/*/SKILL.md found (empty class)"

# --- install.sh link step ---
H="$(mktemp -d)"
STEP="$H/step.sh"
sed -n '/^# --- 1b\. skills:/,/^echo "linked /p' "$ROOT/ops/install.sh" > "$STEP"
grep -q 'ln -sfn' "$STEP" && ok "link step extracted from install.sh" || no "link step not found in install.sh"

mkdir -p "$H/.claude/skills/correct"                      # a REAL dir where a link would go
echo keep > "$H/.claude/skills/correct/mine.txt"
# Negative control: from a linked worktree / feature branch the step must link NOTHING.
G="$(HOME="$H" SRC="$ROOT/ops" OS_LINK_ANY_CHECKOUT=0 bash "$STEP" 2>&1)"
if [ "$(git -C "$ROOT" rev-parse --absolute-git-dir)" != "$(cd "$ROOT" && cd "$(git rev-parse --git-common-dir)" && pwd)" ] || [ "$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)" != master ]; then
  { printf '%s' "$G" | grep -q 'SKIP skills link' && [ ! -e "$H/.claude/skills/blast-radius" ]; } && ok "refuses to link from a worktree/feature branch" || no "linked from a non-main checkout"
fi
export OS_LINK_ANY_CHECKOUT=1   # the remaining cases test link behaviour itself
out="$(HOME="$H" SRC="$ROOT/ops" bash "$STEP" 2>&1)"
[ -f "$H/.claude/skills/correct/mine.txt" ] && [ ! -L "$H/.claude/skills/correct" ] \
  && ok "refuses to clobber a real dir" || no "real dir was clobbered"
printf '%s' "$out" | grep -q 'WARN.*correct' && ok "warns on the skipped dir" || no "no warning for skipped dir"
[ -L "$H/.claude/skills/blast-radius" ] && ok "links blast-radius as a symlink" || no "blast-radius not symlinked"
[ "$(readlink "$H/.claude/skills/blast-radius")" = "$ROOT/skills/blast-radius" ] && ok "symlink targets the repo skill" || no "symlink target wrong"
[ -e "$H/.claude/skills/force-audit" ] && no "force-audit installed by default" || ok "force-audit excluded by default"
HOME="$H" SRC="$ROOT/ops" bash "$STEP" >/dev/null 2>&1 && ok "idempotent re-run exits 0" || no "re-run failed"
HOME="$H" SRC="$ROOT/ops" SKILLS_EXCLUDE="" bash "$STEP" >/dev/null 2>&1
[ -L "$H/.claude/skills/force-audit" ] && ok "SKILLS_EXCLUDE='' opts force-audit in" || no "opt-in did not link force-audit"
rm -rf "$H"

echo "skills-lint: $_pass passed, $_fail failed"
[ "$_fail" -eq 0 ]
