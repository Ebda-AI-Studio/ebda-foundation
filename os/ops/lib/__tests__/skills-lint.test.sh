#!/usr/bin/env bash
# skills/*/SKILL.md must be well-formed (frontmatter name == dir, description <= 1024
# chars, file <= 200 lines) and os/install.sh's skill-link step must SYMLINK and refuse to
# clobber a real directory. The whole installer runs under a temp HOME with a stubbed launchctl.
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

# --- os/install.sh link step (whole installer under a temp HOME and a stubbed launchctl: no real launchd job is touched) ---
H="$(mktemp -d)"
INST="$ROOT/install.sh"
mkdir -p "$H/bin"; printf '#!/bin/sh\nexit 0\n' > "$H/bin/launchctl"; chmod +x "$H/bin/launchctl"
export PATH="$H/bin:$PATH" EBDA_OS_LOCAL_ENV="$H/none.env"
[ -f "$INST" ] && grep -q 'ln -sfn' "$INST" && ok "os/install.sh has the link step" || no "link step not found in os/install.sh"

mkdir -p "$H/home/.claude/skills/correct"                  # a REAL dir where a link would go
echo keep > "$H/home/.claude/skills/correct/mine.txt"
# Negative control: from a linked worktree / feature branch the step must link NOTHING.
G="$(OS_LINK_ANY_CHECKOUT=0 bash "$INST" --home "$H/home" 2>&1)"
if [ "$(git -C "$ROOT" rev-parse --absolute-git-dir)" != "$(cd "$ROOT" && cd "$(git rev-parse --git-common-dir)" && pwd)" ] || [ "$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)" != main ]; then
  { grep -q 'skip   agents + skills links' <<<"$G" && [ ! -e "$H/home/.claude/skills/blast-radius" ]; } && ok "refuses to link from a worktree/feature branch" || no "linked from a non-main checkout"
fi
export OS_LINK_ANY_CHECKOUT=1   # the remaining cases test link behaviour itself
out="$(bash "$INST" --home "$H/home" 2>&1)"
[ -f "$H/home/.claude/skills/correct/mine.txt" ] && [ ! -L "$H/home/.claude/skills/correct" ] \
  && ok "refuses to clobber a real dir" || no "real dir was clobbered"
grep -q 'WARN.*correct' <<<"$out" && ok "warns on the skipped dir" || no "no warning for skipped dir"
[ -L "$H/home/.claude/skills/blast-radius" ] && ok "links blast-radius as a symlink" || no "blast-radius not symlinked"
[ "$(readlink "$H/home/.claude/skills/blast-radius")" = "$ROOT/skills/blast-radius" ] && ok "symlink targets the repo skill" || no "symlink target wrong"
bash "$INST" --home "$H/home" >/dev/null 2>&1 && ok "idempotent re-run exits 0" || no "re-run failed"
rm -rf "$H"

echo "skills-lint: $_pass passed, $_fail failed"
[ "$_fail" -eq 0 ]
