#!/usr/bin/env bash
# merge-train.sh: ordering, rebase-needed, cancel-non-head (free hosted slots), re-run of train-cancelled head runs, migration
# registry, unreadable state refused. Fake `gh` serves fixtures from $FK and logs every mutating call.
set -uo pipefail
OPS="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok() { if [ "$2" = "$3" ]; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1 - got '$2' want '$3'"; fail=$((fail+1)); fi; }
BIN="$T/bin"; FK="$T/fk"; mkdir -p "$BIN" "$FK" "$T/home"
cat > "$BIN/gh" <<'FAKE'
#!/usr/bin/env bash
FK="${FAKE_DIR:?}"
echo "$*" >> "$FK/gh.log"
case "$1 $2" in
  "pr view") f="$FK/pr-$3.json"; [ -f "$f" ] && cat "$f" && exit 0; exit 1 ;;
  "pr edit"|"run cancel"|"run rerun") exit 0 ;;
  "api repos/o/r/pulls/"*) n="${2#repos/o/r/pulls/}"; n="${n%%/*}"; [ -f "$FK/files-$n" ] && cat "$FK/files-$n"; exit 0 ;;
  "api repos/o/r/actions/runs"*)
    sha="$(printf '%s' "$2" | sed -n 's/.*head_sha=\([a-z0-9]*\).*/\1/p')"; st="$(printf '%s' "$2" | sed -n 's/.*status=\([a-z_]*\).*/\1/p')"
    f="$FK/runs-$sha-$st.json"; if [ -f "$f" ]; then cat "$f"; else echo '{"workflow_runs":[]}'; fi; exit 0 ;;
esac
exit 1
FAKE
chmod +x "$BIN/gh"
printf '#!/bin/sh\necho "$*" >> "%s/notify.log"\n' "$FK" > "$T/notify.sh"; chmod +x "$T/notify.sh"
pr() { printf '{"state":"%s","mergeable":"%s","isDraft":false,"headRefOid":"%s"}' "${2:-OPEN}" "${3:-MERGEABLE}" "${4:-sha$1}" > "$FK/pr-$1.json"; }
runs() { printf '{"workflow_runs":[{"id":%s}]}' "$3" > "$FK/runs-$1-$2.json"; }
mt() { PATH="$BIN:$PATH" FAKE_DIR="$FK" HOME="$T/home" OS_STATE_DIR="$T/state" MERGE_TRAIN_NOTIFY="$T/notify.sh" bash "$OPS/merge-train.sh" --repo o/r "$@"; }
STATE="$T/state/merge-train/r.json"

mt add 11 >/dev/null; mt add 12 >/dev/null; mt add 10 2 >/dev/null; mt prio 12 5 >/dev/null
ok "order: wave, then prio desc, then number" "$(mt show | awk '{print $1}' | tr '\n' ' ')" "12 11 10 "
mt after 11 12 >/dev/null
ok "after: 11 blocked by 12" "$(mt show | awk '$1==11{print $4}')" "12"
mt after 12 11 >/dev/null 2>&1; ok "dependency cycle refused" "$?" "2"
mt after 11 999 >/dev/null 2>&1; ok "dependency on unknown PR refused" "$?" "2"
mt add abc >/dev/null 2>&1; ok "non-numeric PR refused" "$?" "2"

# run: 20 conflicts, 21 is the head, 22 loses its runs
rm -f "$STATE"; : > "$FK/gh.log"
mt add 20 >/dev/null; mt add 21 >/dev/null; mt add 22 >/dev/null
pr 20 OPEN CONFLICTING; pr 21 OPEN MERGEABLE aaa111; pr 22 OPEN MERGEABLE bbb222
runs bbb222 in_progress 9001; runs bbb222 queued 9002
out="$(mt run)"
ok "conflicting PR: REBASE-NEEDED" "$(printf '%s\n' "$out" | grep -c '^REBASE-NEEDED 20')" "1"
ok "conflicting PR labelled rebase-needed" "$(grep -c 'pr edit 20 .*--add-label rebase-needed' "$FK/gh.log")" "1"
ok "conflicting PR announced once" "$(grep -c '#20' "$FK/notify.log")" "1"
ok "head = first mergeable (21), conflicting skipped" "$(printf '%s\n' "$out" | grep '^HEAD')" "HEAD 21 aaa111"
ok "non-head run 9001 cancelled" "$(grep -c 'run cancel 9001' "$FK/gh.log")" "1"
ok "non-head run 9002 cancelled" "$(grep -c 'run cancel 9002' "$FK/gh.log")" "1"
ok "only the non-head runs were cancelled" "$(grep -c 'run cancel' "$FK/gh.log")" "2"
ok "cancels recorded as train-cancelled" "$(grep -c 'train-cancelled' "$T/state/merge-train/r.cancelled")" "2"
mt run >/dev/null
ok "second pass: no second notify for the same conflict" "$(grep -c '#20' "$FK/notify.log")" "1"

# head re-run once for a run the train cancelled
rm -f "$FK"/runs-*; : > "$FK/gh.log"
printf '{"workflow_runs":[{"id":7001}]}' > "$FK/runs-aaa111-cancelled.json"
echo "train-cancelled 7001" >> "$T/state/merge-train/r.cancelled"
out="$(mt run)"
ok "head: train-cancelled run re-run" "$(printf '%s\n' "$out" | grep -c '^RERUN 21 run 7001')" "1"
ok "gh run rerun called" "$(grep -c 'run rerun 7001' "$FK/gh.log")" "1"
out="$(mt run)"
ok "re-run happens once" "$(printf '%s\n' "$out" | grep -c '^RERUN')" "0"
printf '{"workflow_runs":[{"id":7002}]}' > "$FK/runs-aaa111-cancelled.json"
out="$(mt run)"
ok "a cancel the train did NOT make is not re-run" "$(printf '%s\n' "$out" | grep -c '^RERUN')" "0"

# dry-run mutates nothing
runs bbb222 in_progress 9100; : > "$FK/gh.log"
mt run --dry-run >/dev/null
ok "dry-run: no cancel/edit/rerun" "$(grep -cE 'run cancel|pr edit|run rerun' "$FK/gh.log")" "0"

# merged PR leaves the queue and resolves dependencies
pr 21 MERGED; mt run >/dev/null
ok "merged PR leaves the queue" "$(mt show | awk '{print $1}' | grep -c '^21$')" "0"
ok "merged recorded" "$(grep -c '"21"' "$STATE")" "1"
pr 21 CLOSED; pr 22 CLOSED; pr 20 CLOSED; mt run >/dev/null; ok "all closed: empty queue" "$(mt show | wc -l | tr -d ' ')" "0"

# migration registry
rm -f "$STATE"; mt add 30 >/dev/null; mt add 31 >/dev/null; mt add 32 >/dev/null
pr 30 OPEN MERGEABLE s30; pr 31 OPEN MERGEABLE s31; pr 32 OPEN MERGEABLE s32
printf 'apps/api/migrations/0201_add_x.sql\n' > "$FK/files-30"; printf 'apps/api/migrations/0202_add_y.sql\n' > "$FK/files-31"; printf 'README.md\n' > "$FK/files-32"
: > "$FK/gh.log"; out="$(mt run)"; rc=$?
ok "distinct migration numbers pass" "$rc" "0"
printf 'apps/api/migrations/201_dup.sql\n' > "$FK/files-31"
: > "$FK/gh.log"; runs s32 in_progress 8001
out="$(mt run)"; rc=$?
ok "duplicate migration number (0201 vs 201): exit 1" "$rc" "1"
ok "collision names both PRs" "$(printf '%s\n' "$out" | grep -c 'COLLISION migration 201 used by PR 30 and PR 31')" "1"
ok "collision pass cancels and merges nothing" "$(grep -cE 'run cancel|run rerun|pr merge' "$FK/gh.log")" "0"
# collision with main (needs --dir)
mkdir -p "$T/repo"
( cd "$T/repo" && git init -q . && mkdir -p apps/api/migrations && : > apps/api/migrations/0300_old.sql \
  && git add apps/api/migrations/0300_old.sql && git -c user.email=a@b -c user.name=n commit -qm m && git update-ref refs/remotes/origin/main HEAD )
printf 'apps/api/migrations/0300_new.sql\n' > "$FK/files-31"
out="$(mt run --dir "$T/repo")"; rc=$?
ok "migration number already on main: exit 1" "$rc:$(printf '%s\n' "$out" | grep -c 'already exists on main')" "1:1"

# unreadable state refused
echo '{broken' > "$STATE"; mt run >/dev/null 2>&1; ok "unreadable state: exit 3, not treated as empty" "$?" "3"
rm -f "$STATE"
mt bogus >/dev/null 2>&1; ok "unknown command exit 2" "$?" "2"
ok "--help exit 0" "$(bash "$OPS/merge-train.sh" --help >/dev/null 2>&1; echo $?)" "0"
echo "---"; echo "merge-train: $pass passed, $fail failed"; [ "$fail" = 0 ]
