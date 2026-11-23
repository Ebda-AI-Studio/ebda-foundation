#!/usr/bin/env bash
# lib/wt-roots.sh + its callers: worktrees and the wt-deps cache live on the SSD (/Volumes/Ebda) when it is mounted and
# writable, else on the internal disk; every lister/cleaner handles BOTH roots; an unmounted SSD never breaks anything.
# Fully isolated: temp HOME, OS_SSD_ROOT points at a temp dir (the real /Volumes/Ebda is never touched), stub df.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; OPS="$HERE/.."
pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1 - got '$2' want '$3'"; fail=$((fail+1)); fi; }
TMP="$(mktemp -d)"; trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"; P="$HOME/Desktop/projects"; export OS_PROJECTS_DIR="$P" PROJECTS_ROOT="$P"
export OS_STATE_DIR="$HOME/.state"
# os-state's TCC canary probes a real repo under the projects dir
mkdir -p "$P/Ebda-AI-Studio/internal-projects/ebda-store/.git"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE OS_WORKTREE_ROOT OS_DEPS_CACHE WT_DEPS_CACHE
SSD="$TMP/ssd"; export OS_SSD_ROOT="$SSD"
res() { ( . "$OPS/lib/wt-roots.sh"; "$@" ); }

# ---- 1. resolver ----
mkdir -p "$SSD"
ok "SSD mounted: worktree root is on the SSD" "$(res wt_worktree_root)" "$SSD/_worktrees"
ok "SSD mounted: cache root is on the SSD (same volume as the worktrees)" "$(res wt_cache_root)" "$SSD/.cache/wt-deps"
rm -rf "$SSD"
ok "SSD absent: worktree root is the internal default" "$(res wt_worktree_root)" "$P/_worktrees"
ok "SSD absent: cache root is the internal default" "$(res wt_cache_root)" "$HOME/.cache/wt-deps"
mkdir -p "$SSD"; chmod 555 "$SSD"
ok "SSD dir present but NOT writable (stale mountpoint): internal" "$(res wt_worktree_root)" "$P/_worktrees"
chmod 755 "$SSD"
ok "OS_WORKTREE_ROOT override beats the SSD" "$(OS_WORKTREE_ROOT=/x/wt res wt_worktree_root)" "/x/wt"
ok "OS_DEPS_CACHE override beats the SSD" "$(OS_DEPS_CACHE=/x/c res wt_cache_root)" "/x/c"
ok "legacy WT_DEPS_CACHE still honoured" "$(WT_DEPS_CACHE=/x/legacy res wt_cache_root)" "/x/legacy"
ok "OS_DEPS_CACHE beats legacy WT_DEPS_CACHE" "$(OS_DEPS_CACHE=/x/new WT_DEPS_CACHE=/x/legacy res wt_cache_root)" "/x/new"
mkdir -p "$P/_worktrees" "$SSD/_worktrees"
ok "wt_all_roots lists both existing roots" "$(res wt_all_roots | tr '\n' ' ')" "$P/_worktrees $SSD/_worktrees "
rm -rf "$SSD/_worktrees"
ok "wt_all_roots skips a missing root" "$(res wt_all_roots | tr '\n' ' ')" "$P/_worktrees "
ok "wt_all_roots does not duplicate an override equal to a root" "$(OS_WORKTREE_ROOT="$P/_worktrees" res wt_all_roots | tr '\n' ' ')" "$P/_worktrees "

# ---- 2. new-task-worktree: floor measured on the CHOSEN volume; fallback + warning ----
mkdir -p "$TMP/bin"
cat > "$TMP/bin/df" <<STUB
#!/bin/sh
# df -k <path>: 900 GB free on the SSD, 1 GB everywhere else
for a in "\$@"; do p="\$a"; done
case "\$p" in "$SSD"*) kb=943718400 ;; *) kb=1048576 ;; esac
echo "Filesystem 1024-blocks Used Available Capacity Mounted"; echo "x 1 1 \$kb 1% /"
STUB
chmod +x "$TMP/bin/df"
git init -q --bare -b main "$TMP/origin.git"
R="$P/Whisky-11/internal-projects/demo"; mkdir -p "$R"
git -C "$R" init -q -b main; git -C "$R" config user.email t@example.invalid; git -C "$R" config user.name t
git -C "$R" remote add origin "$TMP/origin.git"; echo a > "$R/a"; git -C "$R" add a; git -C "$R" commit -q -m init; git -C "$R" push -q origin main
git -C "$R" fetch -q; git -C "$R" remote set-head origin main >/dev/null 2>&1
run_ntw() { PATH="$TMP/bin:$PATH" WT_SKIP_DEPS=1 bash "$OPS/new-task-worktree.sh" "$@"; }

mkdir -p "$SSD"
run_ntw demo feat/ssd >"$TMP/o1" 2>&1; rc=$?
ok "SSD mounted + 900 GB free on it (1 GB internal): worktree is created (floor measured on the SSD)" "$rc" "0"
ok "  ...and it is on the SSD" "$([ -d "$SSD/_worktrees/demo__feat-ssd" ] && echo yes || echo no)" "yes"
ok "  ...and NOT on the internal disk" "$([ -e "$P/_worktrees/demo__feat-ssd" ] && echo yes || echo no)" "no"
ok "  ...and the stamp that arms the fallback warning was written" "$([ -f "$OS_STATE_DIR/wt-ssd-seen" ] && echo yes || echo no)" "yes"
run_ntw demo feat/ssd >"$TMP/o1b" 2>&1
ok "re-running reports 'already exists' (no twin)" "$(grep -c 'already exists' "$TMP/o1b")" "1"

rm -rf "$SSD"
run_ntw demo feat/internal >"$TMP/o2" 2>&1; rc=$?
ok "SSD gone + only 1 GB free internally: refused with exit 3 (floor measured on the internal volume)" "$rc" "3"
ok "  ...the refusal names the fallback" "$(grep -c 'not mounted' "$TMP/o2")" "1"
WT_MIN_FREE_GB=0 run_ntw demo feat/internal >"$TMP/o3" 2>&1; rc=$?
ok "SSD gone: creation falls back to the internal root" "$rc/$([ -d "$P/_worktrees/demo__feat-internal" ] && echo internal)" "0/internal"
ok "  ...with exactly ONE warning line" "$(grep -c '^WARN: SSD' "$TMP/o3")" "1"
ok "an existing SSD-side worktree is still found when the SSD returns (no twin on the internal disk)" "$(mkdir -p "$SSD/_worktrees"; git -C "$R" worktree move "$P/_worktrees/demo__feat-internal" "$SSD/_worktrees/demo__feat-internal" 2>&1 >/dev/null; WT_MIN_FREE_GB=0 run_ntw demo feat/internal 2>&1 | grep -c 'already exists')" "1"
rm -rf "$OS_STATE_DIR/wt-ssd-seen" "$SSD"
WT_MIN_FREE_GB=0 run_ntw demo feat/quiet >"$TMP/o4" 2>&1
ok "a machine that never had the SSD gets NO warning" "$(grep -c '^WARN: SSD' "$TMP/o4")" "0"
ok "WT_MIN_FREE_GB=0 on the 1 GB internal volume still creates (override)" "$([ -d "$P/_worktrees/demo__feat-quiet" ] && echo yes || echo no)" "yes"

# ---- 3. trust: a worktree on the SSD is trusted exactly like one under the projects root ----
mkdir -p "$SSD/_worktrees/tr__a" "$TMP/elsewhere/tr__b"
for d in "$SSD/_worktrees/tr__a" "$TMP/elsewhere/tr__b"; do git -C "$d" init -q; git -C "$d" remote add origin https://github.com/Ebda-AI-Studio/ebda-store.git; done
ok "trust: worktree under the SSD root + trusted origin -> trusted" "$( ( . "$OPS/lib/trusted-origin.sh"; wt_trusted_repo "$SSD/_worktrees/tr__a" && echo yes || echo no ) )" "yes"
ok "trust: same origin in an arbitrary dir -> NOT trusted" "$( ( . "$OPS/lib/trusted-origin.sh"; wt_trusted_repo "$TMP/elsewhere/tr__b" && echo yes || echo no ) )" "no"
git -C "$SSD/_worktrees/tr__a" remote set-url origin https://github.com/evil/x.git
ok "trust: SSD worktree with an EVIL origin -> NOT trusted" "$( ( . "$OPS/lib/trusted-origin.sh"; wt_trusted_repo "$SSD/_worktrees/tr__a" && echo yes || echo no ) )" "no"
rm -rf "$SSD" "$TMP/elsewhere"

# ---- 4. hygiene lists/cleans BOTH roots; a missing root is skipped ----
mkdir -p "$TMP/hops"; cp "$OPS/workspace-hygiene.sh" "$TMP/hops/"; cp -R "$OPS/lib" "$TMP/hops/lib"
HR="$P/Whisky-11/clients/acme/app"; git init -q -b main "$HR"; git -C "$HR" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
mkdir -p "$SSD/_worktrees" "$P/_worktrees"
git -C "$HR" worktree add -q -b feat/live "$SSD/_worktrees/app__feat-live"
git -C "$SSD/_worktrees/app__feat-live" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "unpushed on ssd"
mkdir -p "$SSD/_worktrees/ssdorphan__gone/junk" "$P/_worktrees/intorphan__gone/junk"
DRY_RUN=0 bash "$TMP/hops/workspace-hygiene.sh" >"$TMP/h1" 2>&1; rc=$?
ok "hygiene exits 0 with both roots" "$rc" "0"
ok "orphan on the INTERNAL root removed" "$([ -e "$P/_worktrees/intorphan__gone" ] && echo still || echo gone)" "gone"
ok "orphan on the SSD root removed (SSD root is swept too)" "$([ -e "$SSD/_worktrees/ssdorphan__gone" ] && echo still || echo gone)" "gone"
ok "live SSD worktree with an unpushed commit survives" "$(git -C "$SSD/_worktrees/app__feat-live" log -1 --format=%s 2>/dev/null)" "unpushed on ssd"
ok "digest names the SSD orphan" "$(grep -c 'ssdorphan__gone' "$TMP/h1")" "1"
rm -rf "$SSD"; mkdir -p "$P/_worktrees/intorphan2__gone/junk"
DRY_RUN=0 bash "$TMP/hops/workspace-hygiene.sh" >"$TMP/h2" 2>&1; rc=$?
ok "SSD unmounted: hygiene exits 0 (missing root skipped, not an error)" "$rc" "0"
ok "  ...and still cleans the internal root" "$([ -e "$P/_worktrees/intorphan2__gone" ] && echo still || echo gone)" "gone"
git -C "$HR" worktree prune

# ---- 5. worktree-cleanup + report see both roots ----
rm -rf "$P/_worktrees" "$SSD"; mkdir -p "$SSD/_worktrees/zz__a" "$P/_worktrees/yy__b"
ok "worktree-report counts worktrees on both roots" "$(bash "$OPS/worktree-report.sh" 2>/dev/null | grep -c '^Worktrees: 2 ')" "1"
rm -rf "$SSD"
ok "worktree-report with the SSD unmounted still works (1 root)" "$(bash "$OPS/worktree-report.sh" 2>/dev/null | grep -c '^Worktrees: 1 ')" "1"

# ---- 6. migration script ----
mkdir -p "$SSD/_worktrees"
git -C "$HR" worktree add -q -b feat/idle "$P/_worktrees/app__feat-idle"
git -C "$HR" worktree add -q -b feat/busy "$P/_worktrees/app__feat-busy"
echo wip > "$P/_worktrees/app__feat-idle/dirty.txt"; mkdir -p "$P/_worktrees/app__feat-idle/node_modules/x"; echo n > "$P/_worktrees/app__feat-idle/node_modules/x/i"
printf 'node_modules\n' > "$HR/.git/info/exclude"
IDLE_REAL="$(cd "$P/_worktrees/app__feat-idle" && pwd -P)"; BUSY_REAL="$(cd "$P/_worktrees/app__feat-busy" && pwd -P)"
export MIGRATE_LIVE_CWDS="$BUSY_REAL/sub"
bash "$OPS/migrate-worktrees-to-ssd.sh" >"$TMP/m0" 2>&1; rc=$?
ok "migration dry run (default) changes nothing" "$([ -L "$P/_worktrees/app__feat-idle" ] && echo moved || echo untouched)" "untouched"
ok "  ...and lists the idle one + refuses the busy one" "$(grep -c 'would move: app__feat-idle' "$TMP/m0")/$(grep -c 'BUSY.*app__feat-busy' "$TMP/m0")" "1/1"
bash "$OPS/migrate-worktrees-to-ssd.sh" --apply >"$TMP/m1" 2>&1; rc=$?
ok "migration --apply exits 1 because one worktree was busy" "$rc" "1"
ok "idle worktree now lives on the SSD" "$([ -f "$SSD/_worktrees/app__feat-idle/.git" ] && echo yes || echo no)" "yes"
ok "old path is a symlink to it" "$([ -L "$P/_worktrees/app__feat-idle" ] && [ "$(cd "$P/_worktrees/app__feat-idle" && pwd -P)" = "$(cd "$SSD/_worktrees/app__feat-idle" && pwd -P)" ] && echo yes || echo no)" "yes"
ok "uncommitted file survived (git state kept)" "$(cat "$SSD/_worktrees/app__feat-idle/dirty.txt" 2>/dev/null)" "wip"
ok "git still knows the worktree at the NEW path, branch intact" "$(git -C "$HR" worktree list --porcelain | grep -c "worktree $(cd "$SSD" && pwd -P)/_worktrees/app__feat-idle")/$(git -C "$SSD/_worktrees/app__feat-idle" rev-parse --abbrev-ref HEAD)" "1/feat/idle"
ok "node_modules is not copied (rebuilt by wt-deps)" "$([ -e "$SSD/_worktrees/app__feat-idle/node_modules" ] && echo copied || echo skipped)" "skipped"
ok "BUSY worktree refused: still a real dir on the internal disk" "$([ -d "$P/_worktrees/app__feat-busy" ] && [ ! -L "$P/_worktrees/app__feat-busy" ] && echo kept || echo moved)" "kept"
ok "  ...and nothing of it on the SSD" "$([ -e "$SSD/_worktrees/app__feat-busy" ] && echo yes || echo no)" "no"
bash "$OPS/migrate-worktrees-to-ssd.sh" --apply >"$TMP/m2" 2>&1
ok "re-run is idempotent (idle one skipped as a symlink)" "$(grep -c 'moved: app__feat-idle' "$TMP/m2")" "0"
rm -rf "$SSD"
OS_SSD_ROOT="$SSD" bash "$OPS/migrate-worktrees-to-ssd.sh" --apply >"$TMP/m3" 2>&1; rc=$?
ok "migration with no SSD: exit 2, touches nothing" "$rc/$([ -d "$P/_worktrees/app__feat-busy" ] && echo kept)" "2/kept"

echo "---"; echo "wt-roots: $pass passed, $fail failed"; [ "$fail" = 0 ]
