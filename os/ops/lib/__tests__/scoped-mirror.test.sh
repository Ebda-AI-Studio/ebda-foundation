#!/usr/bin/env bash
# `update-memory-pipeline.sh` promises, in the README it writes into the vault,
# that the mirror makes scoped memory "portable across machines". For an unknown
# stretch it did not: mirror_scoped_to_vault syncs GLOBAL_MEM -> vault only, and
# NOTHING populated GLOBAL_MEM/_scoped from the per-project memory dirs. That
# tree was a stale one-off snapshot, so every scoped memory file written after it
# lived on exactly one Mac.
#
# Measured 2026-09-14, before refresh_scoped_from_projects existed: 50 of 387
# scoped files were absent from the vault — repo-a 11 local / 1 mirrored,
# quote-studio 3 / 0, mypovonai-learn 11 / 0, ebda-store 218 / 208.
#
# Two properties are load-bearing and both are asserted below:
#
#   1. ADDITIVE. Two scopes held MORE in the mirror than on disk
#      (client-repo 9/10, ebda-whatsapp 63/64) because other machines
#      contributed files this Mac never had. A --delete here destroys them.
#   2. NEVER SELF-COPY. Global memory lives under projects/ too. An earlier draft
#      guarded by comparing basenames, which stops guarding the moment GLOBAL_MEM
#      points anywhere else — the first sandbox run copied all 1202 global files
#      into _scoped/<its-own-slug>/. The guard compares inodes for that reason.
#
# Runs against a sandbox HOME, so it never touches real memory.
USER="${USER:-$(id -un)}"; export USER   # unset in minimal containers
set -uo pipefail
OPS="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$OPS/update-memory-pipeline.sh"
_pass=0; _fail=0
ok() { if [ "$2" = 0 ]; then echo "PASS: $1"; _pass=$((_pass+1)); else echo "FAIL: $1"; _fail=$((_fail+1)); fi; }
has()  { if [ -e "$2" ]; then echo "PASS: $1"; _pass=$((_pass+1)); else echo "FAIL: $1 — missing $2"; _fail=$((_fail+1)); fi; }
hasnt(){ if [ ! -e "$2" ]; then echo "PASS: $1"; _pass=$((_pass+1)); else echo "FAIL: $1 — unexpected $2"; _fail=$((_fail+1)); fi; }

[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT not found"; exit 1; }

# Extract the function under test rather than sourcing the script, which runs main().
FN=$(mktemp); trap 'rm -f "$FN"' EXIT
sed -n '/^refresh_scoped_from_projects() {/,/^}/p' "$SCRIPT" > "$FN"
ok "function is extractable from the pipeline script" "$([ -s "$FN" ]; echo $?)"

build_sandbox() {
  SB=$(mktemp -d)
  mkdir -p "$SB/.claude/projects/-Users-${USER:-$(id -un)}-Desktop-projects-repoA/memory" \
           "$SB/.claude/projects/-Users-${USER:-$(id -un)}-Desktop-projects-repoB/memory" \
           "$SB/.claude/projects/-Users-$USER/memory/_scoped/repoA"
  echo '# a'      > "$SB/.claude/projects/-Users-${USER:-$(id -un)}-Desktop-projects-repoA/memory/new.md"
  echo '# b'      > "$SB/.claude/projects/-Users-${USER:-$(id -un)}-Desktop-projects-repoB/memory/only-local.md"
  echo '# global' > "$SB/.claude/projects/-Users-$USER/memory/GLOBAL-SHOULD-NOT-COPY.md"
  # Stands in for a file another machine contributed: present in the mirror, absent on disk.
  echo '# other'  > "$SB/.claude/projects/-Users-$USER/memory/_scoped/repoA/from-other-machine.md"
  G="$SB/.claude/projects/-Users-$USER/memory"
}

run_fn() { HOME="$SB" GLOBAL_MEM="$G" DRY_RUN=0 bash -c ". '$FN'; refresh_scoped_from_projects" >/dev/null 2>&1; }

# ── 1. it actually mirrors ───────────────────────────────────────────────────
build_sandbox; run_fn
has   "a new scoped file reaches the mirror"          "$G/_scoped/repoA/new.md"
has   "a scope with no mirror dir yet is created"     "$G/_scoped/repoB/only-local.md"

# ── 2. additive: never destroys what only the mirror has ─────────────────────
has   "a mirror-only file SURVIVES (no --delete)"     "$G/_scoped/repoA/from-other-machine.md"

# ── 3. never copies global memory into its own _scoped tree ──────────────────
hasnt "global scope is not self-copied"               "$G/_scoped/-Users-$USER"
hasnt "no global file bleeds into a scope"            "$G/_scoped/repoA/GLOBAL-SHOULD-NOT-COPY.md"

# ── 4. idempotent: a second run changes nothing ──────────────────────────────
before=$(find "$G/_scoped" -type f | sort | wc -l)
run_fn
after=$(find "$G/_scoped" -type f | sort | wc -l)
ok "second run is a no-op" "$([ "$before" = "$after" ]; echo $?)"
rm -rf "$SB"

# ── 5. NEGATIVE CONTROL — the self-guard must be watchable failing ───────────
# Strip the inode guard and prove the suite goes red. A guard no test can redden
# is indistinguishable from no guard at all.
MUT=$(mktemp); trap 'rm -f "$FN" "$MUT"' EXIT
grep -v -- '-ef "\$GLOBAL_MEM" \] && continue' "$FN" > "$MUT"
ok "mutant differs from the original" "$([ "$(wc -l < "$MUT")" -lt "$(wc -l < "$FN")" ]; echo $?)"
build_sandbox
HOME="$SB" GLOBAL_MEM="$G" DRY_RUN=0 bash -c ". '$MUT'; refresh_scoped_from_projects" >/dev/null 2>&1
if [ -e "$G/_scoped/-Users-$USER" ]; then
  echo "PASS: removing the guard DOES leak global memory (control fires)"; _pass=$((_pass+1))
else
  echo "FAIL: guard removed and nothing leaked — this suite cannot see the guard"; _fail=$((_fail+1))
fi
rm -rf "$SB"

echo "--- $_pass passed, $_fail failed ---"
[ "$_fail" -eq 0 ]
