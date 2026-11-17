#!/usr/bin/env bash
# ops/lib/projects-layout.sh + ops/projects-layout-check.sh — unit suite.
#
# The layout (Ahmad, 2026-09-25): every business is a folder that holds everything
# about it. A repo lives in exactly one slot:
#   <business>/internal-projects/<repo>        (business = Whisky-11 | Ebda-AI-Studio)
#   <business>/clients/<client>/<repo>
#   Personal/projects/<repo>
# The legacy `_clients/_personal/_landing-pages` paths survive only as compat
# symlinks. Guards: the resolver must find a repo in its NEW slot even when a
# legacy symlink of the same name exists, and the checker must flag a repo that
# sits anywhere else (the positive control: a top-level repo and a _clients repo).
set -uo pipefail
cd "$(dirname "$0")/.."   # -> ops/
OPS="$(pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
_pass=0; _fail=0
pass() { echo "PASS: $1"; _pass=$((_pass+1)); }
fail() { echo "FAIL: $1"; _fail=$((_fail+1)); }

R="$TMP/projects"; mkrepo() { mkdir -p "$R/$1/.git"; }
mkrepo Ebda-AI-Studio/internal-projects/store
mkrepo Whisky-11/clients/globex/globex-menu
mkrepo Whisky-11/internal-projects/whisky11-site
mkrepo Whisky-11/clients/initech/ERP
mkrepo Personal/projects/mypovonai
mkrepo Ebda-AI-Studio/internal-projects/ebda-store
mkrepo Ebda-AI-Studio/clients/acme/acme-site
mkdir -p "$R/_clients" && ln -s ../Whisky-11/clients/globex/globex-menu "$R/_clients/globex-menu"
mkrepo _worktrees/fwb__feat-x; mkrepo _backups/old; mkrepo _archive/dead

export PROJECTS_ROOT="$R"
# shellcheck source=/dev/null
. "$OPS/lib/projects-layout.sh" || { echo "FAIL: cannot source lib/projects-layout.sh"; exit 1; }

[ "$(resolve_repo_dir store)" = "$R/Ebda-AI-Studio/internal-projects/store" ] && pass "resolves an internal project" || fail "internal project: got '$(resolve_repo_dir store)'"
[ "$(resolve_repo_dir globex-menu)" = "$R/Whisky-11/clients/globex/globex-menu" ] && pass "client repo resolves to its NEW slot, not the legacy symlink" || fail "client repo: got '$(resolve_repo_dir globex-menu)'"
[ "$(resolve_repo_dir ERP)" = "$R/Whisky-11/clients/initech/ERP" ] && pass "whisky-11 client resolves" || fail "whisky-11 client"
[ "$(resolve_repo_dir ebda-store)" = "$R/Ebda-AI-Studio/internal-projects/ebda-store" ] && pass "ebda-store canonical name resolves" || fail "ebda-store canonical resolution"
[ "$(resolve_repo_dir ebda)" = "$R/Ebda-AI-Studio/internal-projects/ebda-store" ] && pass "ebda-ai-studio internal project resolves" || fail "ebda: got '$(resolve_repo_dir ebda)'"
[ "$(resolve_repo_dir acme-site)" = "$R/Ebda-AI-Studio/clients/acme/acme-site" ] && pass "ebda-ai-studio client resolves" || fail "ebda client"
[ "$(resolve_repo_dir mypovonai)" = "$R/Personal/projects/mypovonai" ] && pass "personal project resolves" || fail "personal project"
resolve_repo_dir nope >/dev/null && fail "unknown repo must return 1" || pass "unknown repo returns 1"

out=$(bash "$OPS/projects-layout-check.sh" 2>&1); rc=$?
[ $rc -eq 0 ] && pass "clean layout passes (worktrees/backups/archive ignored)" || fail "clean layout flagged: $out"

# positive control: two misplaced repos must be named and fail the check
# (a repo inside a business/ docs folder is the real 2026-10-09 case: Ebda sat at
# Whisky-11/business/ebda/ebda until it got its own business folder)
mkrepo stray-top; mkrepo _clients/stray-client; mkrepo Ebda-AI-Studio/business/ebda/ebda
out=$(bash "$OPS/projects-layout-check.sh" 2>&1); rc=$?
[ $rc -eq 1 ] && pass "misplaced repos fail the check" || fail "misplaced repos not caught (rc=$rc)"
grep -q 'stray-top' <<<"$out" && grep -q '_clients/stray-client' <<<"$out" && grep -q 'Ebda-AI-Studio/business/ebda/ebda' <<<"$out" && pass "all misplaced repos are named" || fail "misplaced not named: $out"

# a pending (declared, not-yet-moved) repo is reported but does not fail
rm -rf "$R/stray-top" "$R/_clients/stray-client" "$R/Ebda-AI-Studio/business"; mkrepo _clients/busy-repo
printf '_clients/busy-repo\tsession active 2026-09-25\n' > "$TMP/pending.tsv"
out=$(PROJECTS_LAYOUT_PENDING="$TMP/pending.tsv" bash "$OPS/projects-layout-check.sh" 2>&1); rc=$?
[ $rc -eq 0 ] && grep -q 'PENDING _clients/busy-repo' <<<"$out" && pass "declared pending move is reported, not failed" || fail "pending handling (rc=$rc): $out"

# --refs: a script that names a project path that no longer exists is a silent
# coverage hole (2026-09-25: agent-dispatch pointed at a deleted digital-card,
# blast-radius at ebda-whatsapp and _clients/digital-card — never real).
rm -rf "$R/_clients/busy-repo"; mkdir -p "$TMP/scripts"
printf 'A="$HOME/Desktop/projects/Ebda-AI-Studio/internal-projects/store"\n' > "$TMP/scripts/ok.sh"
sed -i.bak 's#ebda-os/internal-projects/store#Ebda-AI-Studio/internal-projects/store#' "$TMP/scripts/ok.sh" 2>/dev/null; rm -f "$TMP/scripts/ok.sh.bak"
out=$(bash "$OPS/projects-layout-check.sh" --refs "$TMP/scripts" 2>&1); rc=$?
[ $rc -eq 0 ] && pass "a script naming a real project path passes --refs" || fail "real path flagged: $out"
printf 'B="$HOME/Desktop/projects/_clients/digital-card"\n' > "$TMP/scripts/dead.sh"
out=$(bash "$OPS/projects-layout-check.sh" --refs "$TMP/scripts" 2>&1); rc=$?
[ $rc -eq 1 ] && grep -q 'DEAD _clients/digital-card' <<<"$out" && pass "a dead project path is named and fails --refs" || fail "dead path not caught (rc=$rc): $out"

# a binary file (e.g. a .pyc) that embeds a path must not be reported — grep prints
# "Binary file … matches", which the checker once read as a dead path.
rm -f "$TMP/scripts/dead.sh"; printf 'x\0y Desktop/projects/Ebda-AI-Studio/internal-projects/store\0' > "$TMP/scripts/cache.pyc"
out=$(bash "$OPS/projects-layout-check.sh" --refs "$TMP/scripts" 2>&1); rc=$?
[ $rc -eq 0 ] && ! grep -q 'Binary' <<<"$out" && pass "binary files are skipped by --refs" || fail "binary file reported (rc=$rc): $out"

# list_repo_roots — the ONE repo enumerator. Five scripts listed repos with a
# fixed-depth glob ("$PROJECTS"/*/ or find -maxdepth 1) and went blind after the
# 2026-09-25 reorg put repos 2-3 levels deep. It must return every slot repo,
# never a worktree/backup/archive, never a symlink, and legacy _clients repos too.
got=$(list_repo_roots | sed "s#^$R/##" | LC_ALL=C sort | tr '\n' ' ')
want="Ebda-AI-Studio/clients/acme/acme-site Ebda-AI-Studio/internal-projects/ebda-store Ebda-AI-Studio/internal-projects/store Personal/projects/mypovonai Whisky-11/clients/globex/globex-menu Whisky-11/clients/initech/ERP Whisky-11/internal-projects/whisky11-site _clients/busy-repo "
mkrepo _clients/busy-repo
got=$(list_repo_roots | sed "s#^$R/##" | LC_ALL=C sort | tr '\n' ' ')
[ "$got" = "$want" ] && pass "list_repo_roots finds every slot repo + legacy, skips links/worktrees/backups" || fail "list_repo_roots: got '$got'"

# no script may enumerate repos by hand again (the class, not the instance)
hand=$(grep -rnE '(\$PROJECTS|\$\{PROJECTS\}|\$PROJECTS_DIR)"?/(\*|_\*|_clients/\*|_personal/\*)/|find +"?\$\{?PROJECTS(_DIR)?\}?"? +-maxdepth +1' "$OPS" --include='*.sh' | grep -v -E '/tests/|__tests__|lib/projects-layout.sh' || true)
[ -z "$hand" ] && pass "no ops script enumerates repos with a fixed-depth glob" || fail "hand-rolled repo enumeration: $hand"

# files that never run — *.bak* copies and _retired/ — must not fail --refs:
# 2026-09-25 the installed dir held update-memory-pipeline.sh.bak-20260814-1541 and
# _retired/store-babysit-*.sh, which would have failed os-selftest every day.
rm -f "$TMP/scripts/cache.pyc"; mkdir -p "$TMP/scripts/_retired"
printf 'X="$HOME/Desktop/projects/gone-repo"\n' > "$TMP/scripts/old.sh.bak-20260814-1541"
printf 'Y="$HOME/Desktop/projects/gone-repo"\n' > "$TMP/scripts/_retired/old.sh"
out=$(bash "$OPS/projects-layout-check.sh" --refs "$TMP/scripts" 2>&1); rc=$?
[ $rc -eq 0 ] && pass "backup copies and _retired/ are not scanned by --refs" || fail "non-running files flagged (rc=$rc): $out"

# <business>/studio/app (Ahmad 2026-11-09, ported from the predecessor OS): the studio's code repo is a valid slot in every business; its sibling folders
# (business/, shared/) are LOCAL media and must never hold a repo, and nothing may nest inside app/.
layout_slot_ok "Whisky-11/studio/app" && pass "studio/app is a valid slot" || fail "Whisky-11/studio/app rejected"
layout_slot_ok "Ebda-AI-Studio/studio/app" && layout_slot_ok "Acme-Co/studio/app" && pass "studio/app is valid in every business" || fail "studio/app not valid in every business"
layout_slot_ok "Whisky-11/studio/shared" && fail "studio/shared accepted as a repo slot" || pass "studio/shared is not a repo slot"
layout_slot_ok "Whisky-11/studio/business" && fail "studio/business accepted as a repo slot" || pass "studio/business is not a repo slot"
layout_slot_ok "Whisky-11/studio/app/nested" && fail "a repo nested in studio/app accepted" || pass "nothing nests inside studio/app"
layout_slot_ok "Whisky-11/studio" && fail "studio itself accepted as a repo slot" || pass "studio itself is not a repo slot"
R2="$TMP/projects2"; mkdir -p "$R2"; mk2() { mkdir -p "$R2/$1/.git"; }
mk2 Whisky-11/studio/app; mk2 Whisky-11/studio/shared; mk2 Whisky-11/internal-projects/whisky11-site
got=$(PROJECTS_ROOT="$R2" bash -c ". '$OPS/lib/projects-layout.sh'; list_repo_roots" | sed "s#^$R2/##" | LC_ALL=C sort | tr '\n' ' ')
[ "$got" = "Whisky-11/internal-projects/whisky11-site Whisky-11/studio/app " ] && pass "list_repo_roots lists studio/app (and not studio/shared)" || fail "list_repo_roots with studio: got '$got'"
out=$(PROJECTS_ROOT="$R2" bash "$OPS/projects-layout-check.sh" 2>&1); rc=$?
{ [ "$rc" = 1 ] && grep -q '^MISPLACED Whisky-11/studio/shared' <<<"$out" && ! grep -q 'MISPLACED Whisky-11/studio/app' <<<"$out"; } && pass "the checker flags studio/shared, not studio/app" || fail "checker with studio: rc=$rc out=$out"

echo "projects-layout: $_pass passed, $_fail failed"
[ "$_fail" -eq 0 ]
