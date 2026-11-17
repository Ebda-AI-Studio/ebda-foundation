#!/usr/bin/env bash
# Ruling PIPEFAIL-GREP-Q-1: no `cmd | grep -q ...` inside a `set -o pipefail` shell file (scripts AND tests).
# Why: grep -q exits at the first match; a producer that is still writing takes SIGPIPE, and under pipefail the pipeline then reports FAILURE although the
# pattern WAS found. With a large producer output that is a race (os/tests/install-dryrun.test.sh and ops-lib/skills-lint failed 10 times in 36 under
# load: "not found"); in a guard `! cmd | grep -q` it turns a real match into "absent". Use `grep -q PAT <<<"$var"` or `grep -q PAT < <(cmd)`.
# Scans every tracked *.sh that sets pipefail. A line may opt out with `# pipefail-grep-ok: <reason>` when the producer is known to be tiny. Comments are ignored.
# Negative controls below prove the check can fail. Usage: bash os/tests/no-pipe-grep-q.test.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 1
p=0; f=0
ok() { echo "PASS: $1"; p=$((p+1)); }
no() { echo "FAIL: $1"; f=$((f+1)); }

# prints "file:line: text" for every offending line of the files given
scan() {
  python3 -I - "$@" <<'PY'
import re, sys
sink = re.compile(r"\|\s*(?:/usr/bin/|/bin/)?grep\s+(?:-[A-Za-z]+\s+)*(?:-[A-Za-z]*q[A-Za-z]*|--quiet|--silent)\b")
pipefail = re.compile(r"set\s+(?:-[A-Za-z]+\s+)*-[A-Za-z]*o\s+pipefail|set\s+-[A-Za-z]*o\s+pipefail|set\s+-o\s+pipefail|set -euo pipefail|set -uo pipefail")
for path in sys.argv[1:]:
    if path.endswith("os/tests/no-pipe-grep-q.test.sh"):
        continue  # this file carries the bad shapes as negative-control fixtures
    try:
        text = open(path, encoding="utf-8").read()
    except OSError:
        continue
    if not pipefail.search(text):
        continue
    for n, line in enumerate(text.split("\n"), 1):
        if re.match(r"\s*#", line) or "pipefail-grep-ok:" in line:
            continue
        if sink.search(line):
            print(f"{path}:{n}: {line.strip()[:140]}")
PY
}

# ---- negative controls: the scanner flags the bad shapes and passes the good ones
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
printf '%s\n' '#!/usr/bin/env bash' 'set -uo pipefail' 'printf "%s" "$x" | grep -q foo && echo y' > "$T/bad1.sh"
printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' 'if ! launchctl list | grep -qF "$l"; then :; fi' > "$T/bad2.sh"
printf '%s\n' '#!/usr/bin/env bash' 'set -o pipefail' 'cmd | grep -iq pat' > "$T/bad3.sh"
printf '%s\n' '#!/usr/bin/env bash' 'set -uo pipefail' 'grep -q foo <<<"$x" && echo y' 'grep -q foo < <(cmd)' '# cmd | grep -q commented' 'cmd | grep -v x | wc -l' 'cmd | grep foo' > "$T/good.sh"
printf '%s\n' '#!/usr/bin/env bash' 'cmd | grep -q foo   # no pipefail in this file' > "$T/nopf.sh"
printf '%s\n' '#!/usr/bin/env bash' 'set -uo pipefail' 'echo hi | grep -q hi  # pipefail-grep-ok: one short literal' > "$T/pragma.sh"
[ -n "$(scan "$T/bad1.sh")" ] && ok "flags printf | grep -q under pipefail" || no "missed printf | grep -q"
[ -n "$(scan "$T/bad2.sh")" ] && ok "flags a launchctl list | grep -qF guard (set -euo pipefail)" || no "missed the launchctl guard shape"
[ -n "$(scan "$T/bad3.sh")" ] && ok "flags grep -iq (q among the flags)" || no "missed -iq"
[ -z "$(scan "$T/good.sh")" ] && ok "passes here-strings, process substitution, comments and a non-quiet grep" || no "false positive: $(scan "$T/good.sh")"
[ -z "$(scan "$T/nopf.sh")" ] && ok "ignores a file that does not set pipefail" || no "flagged a non-pipefail file"
[ -z "$(scan "$T/pragma.sh")" ] && ok "honours a '# pipefail-grep-ok: reason' line" || no "pragma ignored"

# ---- the repo: every tracked shell file
if git rev-parse --git-dir >/dev/null 2>&1; then files="$(git ls-files '*.sh')"; else files="$(find . -name '*.sh' -not -path './node_modules/*' | sed 's|^\./||')"; fi
# shellcheck disable=SC2086
hits="$(scan $files)"
if [ -z "$hits" ]; then ok "no 'cmd | grep -q' in any pipefail shell file ($(printf '%s\n' "$files" | wc -l | tr -d ' ') files)"
else no "cmd | grep -q under pipefail (use a here-string or process substitution):"; printf '%s\n' "$hits" | sed 's/^/    /'; fi

echo "no-pipe-grep-q: $p passed, $f failed"; [ "$f" = 0 ]
