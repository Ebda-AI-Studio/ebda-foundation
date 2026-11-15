#!/usr/bin/env bash
# G14: a scheduled job that exits non-zero opens ONE review-finding issue per job per day, with the log tail (secrets masked).
# Before 2026-11-15 os-selftest only judged log freshness, so an on-time job that exited 1 reached nobody.
# Run: bash os/ops/lib/__tests__/job-failure.test.sh
set -uo pipefail
OPS="$(cd "$(dirname "$0")/../.." && pwd)"
_pass=0; _fail=0
ok() { echo "PASS: $1"; _pass=$((_pass+1)); }
no() { echo "FAIL: $1"; _fail=$((_fail+1)); }
[ -f "$OPS/lib/job-failure.sh" ] || { no "lib/job-failure.sh missing"; echo "job-failure: 0 passed, 1 failed"; exit 1; }
. "$OPS/lib/job-failure.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export OS_REPO_SLUG="x/y" JF_FAILURE_STATE="$T/state" HOME="$T/home"; mkdir -p "$HOME"
cat > "$T/gh" <<'F'
#!/usr/bin/env bash
echo "$*" >> "${GH_LOG:?}"
case "$1 $2" in "issue create") cat >> "$GH_LOG.body" <<<"$*"; [ -f "$GH_LOG.fail" ] && exit 1; echo "https://github.com/x/y/issues/9";; esac
F
chmod +x "$T/gh"; export JF_FAILURE_GH="$T/gh" GH_LOG="$T/gh.log"
printf 'work\nTOKEN=abc123supersecret\nboom: backup failed\n' > "$T/err.log"
cat > "$T/job.plist" <<P
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>StandardErrorPath</key><string>$T/err.log</string></dict></plist>
P
printf 'x = {\n\tlast exit code = 1\n}\n' > "$T/p1"; printf 'x = {\n\tlast exit code = (never exited)\n}\n' > "$T/p2"; printf 'last exit code = 0\n' > "$T/p3"
[ "$(JF_LAUNCHCTL_PRINT="$T/p1" jf_last_exit a)" = 1 ] && ok "parses a non-zero last exit code" || no "exit code not parsed"
[ -z "$(JF_LAUNCHCTL_PRINT="$T/p2" jf_last_exit a)" ] && ok "never-exited job reports nothing" || no "never exited treated as a code"
[ "$(JF_LAUNCHCTL_PRINT="$T/p3" jf_last_exit a)" = 0 ] && ok "exit 0 parsed as 0" || no "exit 0 not parsed"
r="$(job_failure_report com.ebda.os.backup 0 "$T/job.plist")"; [ "$r" = "SKIPPED exit-0" ] && [ ! -f "$GH_LOG" ] && ok "exit 0 files nothing" || no "exit 0 filed an issue: $r"
touch "$GH_LOG.fail"; r="$(job_failure_report com.ebda.os.backup 1 "$T/job.plist")"; rm -f "$GH_LOG.fail"
[ "$r" = "SKIPPED gh-failed" ] && ok "failed filing is not stamped" || no "failed filing result: $r"
r="$(job_failure_report com.ebda.os.backup 1 "$T/job.plist")"; case "$r" in "FILED "*) ok "non-zero exit files an issue";; *) no "no issue filed: $r";; esac
grep -q -- "--label review-finding" "$GH_LOG" && ok "issue carries the review-finding label" || no "label missing"
grep -q "boom: backup failed" "$GH_LOG.body" && ok "issue body has the log tail" || no "log tail missing"
grep -q "abc123supersecret" "$GH_LOG.body" && no "secret leaked into the issue" || ok "secret in the log tail is masked"
r="$(job_failure_report com.ebda.os.backup 1 "$T/job.plist")"; [ "$r" = DEDUPED ] && ok "same job same day is deduped" || no "not deduped: $r"
r="$(job_failure_report com.ebda.os.other 2 "$T/job.plist")"; case "$r" in "FILED "*) ok "a different job still files";; *) no "other job blocked: $r";; esac
grep -q 'check_last_exit "\$plist"' "$OPS/os-selftest.sh" && ok "os-selftest calls check_last_exit for every job" || no "os-selftest does not call check_last_exit"
echo "job-failure: $_pass passed, $_fail failed"; [ "$_fail" = 0 ]
