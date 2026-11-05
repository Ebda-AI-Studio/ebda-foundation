#!/usr/bin/env bash
# merge-gate: the 2026-10-25 defect (zero checks read as green) and its siblings, against a faked `gh pr view`.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; OPS="$HERE/.."
pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1 - got '$2' want '$3'"; fail=$((fail+1)); fi; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
WF="$TMP/wf"; mkdir -p "$WF"
cat > "$WF/ci.yml" <<'Y'
name: CI
on:
  pull_request:
    branches: [main]
jobs:
  lint:
    name: Lint
    runs-on: x
  test:
    name: Unit
    if: needs.changes.outputs.code == 'true'
    needs: lint
    runs-on: x
  gate:
    name: Gate
    needs: lint
    runs-on: x
Y
cat > "$WF/nightly.yml" <<'Y'
on:
  schedule:
    - cron: '0 0 * * *'
jobs:
  heavy:
    name: Heavy
Y
req="$(python3 -I "$OPS/lib/merge_gate.py" required "$WF")"
ok "required derived from workflows (always-run PR jobs only)" "$req" '["Gate", "Lint"]'

# an aggregator that runs even when the jobs it needs were skipped is required; the conditional matrix job is not
WF2="$TMP/wf2"; mkdir -p "$WF2"
cat > "$WF2/ci.yml" <<'Y'
on:
  pull_request:
jobs:
  changes:
    name: Detect
    if: github.event_name == 'pull_request'
  app-build:
    name: Build (${{ matrix.app }})
    needs: [changes]
    if: needs.changes.outputs.x == 'true'
  app-builds:
    name: App builds (affected)
    needs: [changes, app-build]
    if: always() && github.event_name == 'pull_request'
Y
ok "always() aggregator is required, conditional matrix job is not" "$(python3 -I "$OPS/lib/merge_gate.py" required "$WF2")" '["App builds (affected)", "Detect"]'

ev() { python3 -I "$OPS/lib/merge_gate.py" evaluate "$1" "$req"; }
SHA=abcdef1234567890
pr() { printf '{"headRefOid":"%s","mergeable":"%s","statusCheckRollup":%s}' "$SHA" "${2:-MERGEABLE}" "$1"; }
c() { printf '{"__typename":"CheckRun","name":"%s","status":"%s","conclusion":"%s"}' "$1" "$2" "$3"; }
ok "ZERO checks is wait, never ok"            "$(pr '[]' | ev abcdef1)" "wait:no checks have reported yet"
ok "null rollup is wait, never ok"            "$(pr null | ev abcdef1)" "wait:no checks have reported yet"
ok "all green incl. required => ok"           "$(pr "[$(c Lint COMPLETED SUCCESS),$(c Gate COMPLETED SUCCESS),$(c Unit COMPLETED SKIPPED)]" | ev abcdef1)" "ok"
ok "required check only SKIPPED => wait"      "$(pr "[$(c Lint COMPLETED SUCCESS),$(c Gate COMPLETED SKIPPED)]" | ev abcdef1)" "wait:required check(s) without an explicit SUCCESS: Gate"
ok "one pending => wait"                      "$(pr "[$(c Lint COMPLETED SUCCESS),$(c Gate IN_PROGRESS '')]" | ev abcdef1)" "wait:not finished: Gate"
ok "a failure => refuse"                      "$(pr "[$(c Lint COMPLETED FAILURE),$(c Gate COMPLETED SUCCESS)]" | ev abcdef1)" "refuse:failing check(s): Lint"
ok "cancelled => refuse, named as cancelled"  "$(pr "[$(c Lint COMPLETED CANCELLED)]" | ev abcdef1)" "refuse:cancelled (infra or controller), re-run: Lint"
ok "head moved => refuse"                     "$(pr "[$(c Lint COMPLETED SUCCESS),$(c Gate COMPLETED SUCCESS)]" | ev 1111111)" "refuse:head moved to abcdef123 (expected 1111111)"
ok "conflicting => refuse rebase needed"      "$(pr "[$(c Lint COMPLETED SUCCESS),$(c Gate IN_PROGRESS '')]" CONFLICTING | ev abcdef1 | cut -c1-29)" "refuse:rebase needed - this P"
ok "unknown mergeable still waits"            "$(pr "[$(c Lint COMPLETED SUCCESS),$(c Gate COMPLETED SUCCESS)]" UNKNOWN | ev abcdef1)" "wait:mergeable=UNKNOWN"
ok "StatusContext pending => wait"            "$(pr '[{"__typename":"StatusContext","context":"ci/x","state":"PENDING"}]' | ev abcdef1)" "wait:not finished: ci/x"

# --- the shell driver: merge only after N consecutive greens; zero checks never merges ---
GREEN="$(pr "[$(c Lint COMPLETED SUCCESS),$(c Gate COMPLETED SUCCESS)]")"
printf '%s' "$GREEN" > "$TMP/green.json"; printf '%s' "$(pr '[]')" > "$TMP/none.json"
run() {  # $1=view json file ; rest = extra args
  local f="$1"; shift; rm -f "$TMP/merged"
  MERGE_GATE_VIEW_CMD="cat $f" MERGE_GATE_MERGE_CMD="echo merged > $TMP/merged" \
    bash "$OPS/merge-gate.sh" 7 abcdef1 --workflows "$WF" --interval 0 "$@" >"$TMP/out" 2>&1; echo $?
}
ok "green x3 merges (exit 0)"        "$(run "$TMP/green.json" --polls 3)" "0"
ok "  ...and actually ran the merge" "$([ -f "$TMP/merged" ] && echo yes || echo no)" "yes"
ok "dry-run never merges"            "$(run "$TMP/green.json" --polls 2 --dry-run)" "0"
ok "  ...merge cmd not run"          "$([ -f "$TMP/merged" ] && echo yes || echo no)" "no"
ok "ZERO checks never merges (exit 2 after max wait)" "$(MERGE_GATE_MAX_WAIT_S=1 run "$TMP/none.json" --polls 3)" "2"
ok "  ...merge cmd not run"          "$([ -f "$TMP/merged" ] && echo yes || echo no)" "no"
ok "no PR workflows => refuse (2)"   "$(mkdir -p "$TMP/empty"; MERGE_GATE_VIEW_CMD="cat $TMP/green.json" bash "$OPS/merge-gate.sh" 7 abcdef1 --workflows "$TMP/empty" >/dev/null 2>&1; echo $?)" "2"
ok "short sha rejected (64)"         "$(bash "$OPS/merge-gate.sh" 7 abc >/dev/null 2>&1; echo $?)" "64"
echo "---"; echo "merge-gate: $pass passed, $fail failed"; [ "$fail" = 0 ]
