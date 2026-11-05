#!/usr/bin/env bash
# An EMPTY array expanded as "${A[@]}" is an UNBOUND VARIABLE under bash 3.2 +
# `set -u`. macOS ships bash 3.2 and there is no newer bash on the launchd PATH,
# so every ops script runs under exactly those semantics.
#
# 2026-08-25: deploy-drift.sh died at `for f in "${FAILS[@]}"` on 32 consecutive
# hourly runs. It had 0 fails and 1 alert; the guard above that line only
# checked fails+alerts > 0. It detected a real whatsapp prod drift, printed it, then
# aborted before write_status — so the drift went unreported AND the stale
# status file made the job look merely dead. Both symptoms, one missing `+`.
#
# This is the same class as the `declare -A` bash-4 assumption that silently
# disabled heal-watch's os-heal block for its whole life.
#
# This suite is also the GATE: part 3 fails if any ops script reintroduces a
# bare expansion of an accumulator array.
set -uo pipefail
OPS="$(cd "$(dirname "$0")/../.." && pwd)"
_pass=0; _fail=0
eq() { if [ "$2" = "$3" ]; then echo "PASS: $1"; _pass=$((_pass+1)); else echo "FAIL: $1 — got '$2' want '$3'"; _fail=$((_fail+1)); fi; }
ok() { if [ "$2" = 0 ]; then echo "PASS: $1"; _pass=$((_pass+1)); else echo "FAIL: $1"; _fail=$((_fail+1)); fi; }
no() { if [ "$2" != 0 ]; then echo "PASS: $1"; _pass=$((_pass+1)); else echo "FAIL: $1 — expected failure, got success"; _fail=$((_fail+1)); fi; }

# ── 0. does THIS host's bash exhibit the hazard? ─────────────────────────────
# bash 4.4 stopped treating an empty array's expansion as unbound. macOS ships
# 3.2 and launchd invokes /bin/bash, so production always has the hazard; Linux
# CI runs bash 5 and never can. The demo below is therefore host-conditional —
# and its being unreproducible on CI is exactly why part 3 is a STATIC gate
# rather than a runtime test.
if bash -uc 'A=(); for x in "${A[@]}"; do :; done' 2>/dev/null; then
  HAZARD=0; echo "NOTE: bash $BASH_VERSION does not exhibit the hazard (>=4.4) — demo skipped, gate still enforced"
else
  HAZARD=1; echo "NOTE: bash $BASH_VERSION exhibits the hazard (<4.4) — same as production /bin/bash"
fi

# ── 1. the hazard is real, and the guard removes it ──────────────────────────
# Run in a child shell so the abort is observable rather than fatal here.
if [ "$HAZARD" = 1 ]; then
  bash -uc 'A=(); for x in "${A[@]}"; do :; done' 2>/dev/null; rc=$?
  no  "bare expansion of an empty array aborts under set -u" "$rc"
else
  echo "SKIP: bare-expansion abort (needs bash <4.4)"
fi

# The guard must work on EVERY bash, or the fix would be host-dependent.
bash -uc 'A=(); for x in ${A[@]+"${A[@]}"}; do :; done' 2>/dev/null; rc=$?
ok  "guarded expansion of an empty array survives" "$rc"

# The guard must be a NO-OP when the array has elements — same count, same
# splitting, whitespace preserved. A guard that silently dropped or re-split
# entries would be worse than the crash it replaces.
n=$(bash -uc 'A=(one "two three" four); printf "%s\n" ${A[@]+"${A[@]}"} | wc -l')
eq  "guard preserves element count"      "$(echo "$n" | tr -d ' ')" "3"
v=$(bash -uc 'A=(one "two three" four); printf "[%s]" ${A[@]+"${A[@]}"}')
eq  "guard preserves embedded whitespace" "$v" "[one][two three][four]"
v=$(bash -uc 'A=("a b"); B=(${A[@]+"${A[@]}"}); echo "${#B[@]}"')
eq  "guard is word-safe in array assignment" "$v" "1"

# ── 2. the exact deploy-drift shape: 0 fails, 1 alert ────────────────────────
if [ "$HAZARD" = 1 ]; then
  bash -uc 'FAILS=(); ALERTS=("whatsapp api: DRIFT")
    parts=()
    for f in "${FAILS[@]}"; do parts+=("FAIL: $f"); done
    for a in "${ALERTS[@]}"; do parts+=("ALERT: $a"); done' 2>/dev/null; rc=$?
  no  "the 0-fail/1-alert shape aborts unguarded" "$rc"
else
  echo "SKIP: 0-fail/1-alert abort (needs bash <4.4)"
fi

out=$(bash -uc 'FAILS=(); ALERTS=("whatsapp api: DRIFT")
  parts=()
  for f in ${FAILS[@]+"${FAILS[@]}"}; do parts+=("FAIL: $f"); done
  for a in ${ALERTS[@]+"${ALERTS[@]}"}; do parts+=("ALERT: $a"); done
  printf "%s\n" ${parts[@]+"${parts[@]}"}' 2>/dev/null)
eq  "the 0-fail/1-alert shape survives guarded" "$out" "ALERT: whatsapp api: DRIFT"

# ── 3. GATE: no ops script may reintroduce a bare accumulator expansion ──────
report=$(OPS="$OPS" python3 - <<'PY'
import io, os, re, sys
ops = os.environ["OPS"]
bad = []
for root, dirs, files in os.walk(ops):
    dirs[:] = [d for d in dirs if d not in ('.git', 'node_modules', '__tests__')]
    for fn in sorted(files):
        if not fn.endswith('.sh'):
            continue
        p = os.path.join(root, fn)
        try:
            s = io.open(p, encoding='utf-8').read()
        except Exception:
            continue
        if not re.search(r'set -[a-z]*u', s):
            continue          # no `set -u`, no hazard
        # Scan CODE, not prose. A full-line comment that DOCUMENTS the correct
        # form necessarily contains the bare form it warns against, so without
        # this the guard fails the very file that explains its own rule (hit
        # 2026-09-23 in worktree-cleanup.sh). Only whole-line comments are
        # stripped: a general `#`-to-EOL strip would eat `${var#prefix}` and a
        # `#` inside a string. The line CONTENT is removed but the newline is
        # kept, so reported line numbers stay correct.
        s = re.sub(r'(?m)^[ \t]*#.*$', '', s)
        # An accumulator array: declared empty, or built with +=. Either way it
        # starts life empty and can still be empty at expansion time.
        arrs = set(re.findall(r'([A-Za-z_][A-Za-z0-9_]*)=\(\)', s)) | \
               set(re.findall(r'([A-Za-z_][A-Za-z0-9_]*)\+=\(', s))
        for a in sorted(arrs):
            for m in re.finditer(r'"\$\{' + re.escape(a) + r'\[@\]\}"', s):
                # already inside ${a[@]+ ... } ?
                if ('${%s[@]+' % a) in s[max(0, m.start() - len(a) - 8):m.start()]:
                    continue
                line = s[:m.start()].count('\n') + 1
                bad.append('%s:%d: bare "${%s[@]}" — use ${%s[@]+"${%s[@]}"}'
                           % (os.path.relpath(p, ops), line, a, a, a))
sys.stdout.write('\n'.join(bad))
PY
)
if [ -z "$report" ]; then
  echo "PASS: no bare accumulator-array expansions in ops/"; _pass=$((_pass+1))
else
  echo "FAIL: bare accumulator-array expansions found:"; printf '%s\n' "$report" | sed 's/^/       /'
  _fail=$((_fail+1))
fi

echo; echo "$_pass passed, $_fail failed"; [ "$_fail" -eq 0 ]
