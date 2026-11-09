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

# --- a path-filtered pull_request workflow contributes NO required check: GitHub creates no check run for a PR outside
#     the filter, so requiring one waits the full --max-wait-min for a check that will never exist (ebda-store PR 490,
#     blast-radius.yml, 2026-11-09). A filter on `push` only changes nothing. The fork guard counts as always-on. ---
WF3="$TMP/wf3"; mkdir -p "$WF3"
cat > "$WF3/every.yml" <<'Y'
on:
  pull_request:
    branches: [main]
jobs:
  every:
    name: EveryPr
Y
cat > "$WF3/ignore.yml" <<'Y'
on:
  pull_request:
    branches: [main]
    paths-ignore:
      - 'docs/**'
      - '*.md'
  workflow_dispatch:
jobs:
  blast:
    name: BlastRadius
Y
cat > "$WF3/paths.yml" <<'Y'
on:
  pull_request:
    paths:
      - 'apps/**'
jobs:
  apps:
    name: AppsOnly
Y
cat > "$WF3/inline.yml" <<'Y'
on:
  pull_request: { paths: ['infra/**'] }
jobs:
  infra:
    name: InfraInline
Y
cat > "$WF3/flow.yml" <<'Y'
on: { pull_request: { paths-ignore: ['docs/**'] }, push: { branches: [main] } }
jobs:
  flow:
    name: FlowInline
Y
cat > "$WF3/pushonly.yml" <<'Y'
on:
  push:
    branches: [main]
    paths:
      - 'apps/**'
  pull_request:
jobs:
  p:
    name: PushFilteredOnly
Y
cat > "$WF3/pushonly2.yml" <<'Y'
on:
  pull_request:
    branches: [main]
  push:
    paths-ignore:
      - 'docs/**'
jobs:
  p:
    name: PushFilteredOnly2
Y
req3="$(python3 -I "$OPS/lib/merge_gate.py" required "$WF3")"
ok "path-filtered pull_request (paths, paths-ignore, block + inline) is not required; a push-only filter still is" "$req3" '["EveryPr", "PushFilteredOnly", "PushFilteredOnly2"]'
WF4="$TMP/wf4"; mkdir -p "$WF4"
cat > "$WF4/ci.yml" <<'Y'
on:
  pull_request:
jobs:
  guarded:
    name: Guarded
    if: github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository
  other:
    name: Other
    if: github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository && false
Y
ok "a job whose if is exactly the fork guard always runs on a same-repo PR: required" "$(python3 -I "$OPS/lib/merge_gate.py" required "$WF4")" '["Guarded"]'

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

# --- latest run wins: the rollup keeps OLD runs of a same-name check on the same head. A superseded run (cancelled by
#     a concurrency group, then re-run green) must not refuse forever (ebda-whatsapp PR 56, 2026-11-09: CANCELLED at
#     21:16:28Z, SUCCESS at 21:16:32Z, gate refused twice). The reverse (older pass, newer fail) still refuses. ---
ct() { printf '{"__typename":"CheckRun","name":"%s","status":"%s","conclusion":"%s","startedAt":"%s","completedAt":"%s"}' "$1" "$2" "$3" "$4" "${5:-0001-01-01T00:00:00Z}"; }
T1=2026-11-09T21:16:28Z; T2=2026-11-09T21:16:32Z
G="$(c Gate COMPLETED SUCCESS)"
ok "cancelled then success, same name => ok"            "$(pr "[$(ct Lint COMPLETED CANCELLED $T1 $T1),$(ct Lint COMPLETED SUCCESS $T2 $T2),$G]" | ev abcdef1)" "ok"
ok "  ...the timestamp decides, not rollup order"       "$(pr "[$(ct Lint COMPLETED SUCCESS $T2 $T2),$(ct Lint COMPLETED CANCELLED $T1 $T1),$G]" | ev abcdef1)" "ok"
ok "failure then success, same name => ok"              "$(pr "[$(ct Lint COMPLETED FAILURE $T1 $T1),$(ct Lint COMPLETED SUCCESS $T2 $T2),$G]" | ev abcdef1)" "ok"
ok "success then failure, same name => refuse"          "$(pr "[$(ct Lint COMPLETED SUCCESS $T1 $T1),$(ct Lint COMPLETED FAILURE $T2 $T2),$G]" | ev abcdef1)" "refuse:failing check(s): Lint"
ok "  ...also when the rollup lists the failure first"  "$(pr "[$(ct Lint COMPLETED FAILURE $T2 $T2),$(ct Lint COMPLETED SUCCESS $T1 $T1),$G]" | ev abcdef1)" "refuse:failing check(s): Lint"
ok "success then cancelled, same name => refuse"        "$(pr "[$(ct Lint COMPLETED SUCCESS $T1 $T1),$(ct Lint COMPLETED CANCELLED $T2 $T2),$G]" | ev abcdef1)" "refuse:cancelled (infra or controller), re-run: Lint"
ok "success then a re-run still in progress => wait"    "$(pr "[$(ct Lint COMPLETED SUCCESS $T1 $T1),$(ct Lint IN_PROGRESS '' $T2),$G]" | ev abcdef1)" "wait:not finished: Lint"
ok "failure then a re-run still in progress => wait"    "$(pr "[$(ct Lint COMPLETED FAILURE $T1 $T1),$(ct Lint IN_PROGRESS '' $T2),$G]" | ev abcdef1)" "wait:not finished: Lint"
ok "a queued re-run with no start time is the newest"   "$(pr "[$(ct Lint QUEUED '' 0001-01-01T00:00:00Z),$(ct Lint COMPLETED SUCCESS $T1 $T1),$G]" | ev abcdef1)" "wait:not finished: Lint"
ok "same timestamp: the later rollup entry wins (fail)" "$(pr "[$(ct Lint COMPLETED SUCCESS $T1 $T1),$(ct Lint COMPLETED FAILURE $T1 $T1),$G]" | ev abcdef1)" "refuse:failing check(s): Lint"
ok "same timestamp: the later rollup entry wins (pass)" "$(pr "[$(ct Lint COMPLETED FAILURE $T1 $T1),$(ct Lint COMPLETED SUCCESS $T1 $T1),$G]" | ev abcdef1)" "ok"
ok "an old SUCCESS does not satisfy a required check whose latest run was SKIPPED" "$(pr "[$(ct Gate COMPLETED SUCCESS $T1 $T1),$(ct Gate COMPLETED SKIPPED $T2 $T2),$(c Lint COMPLETED SUCCESS)]" | ev abcdef1)" "wait:required check(s) without an explicit SUCCESS: Gate"
sc() { printf '{"__typename":"StatusContext","context":"%s","state":"%s","createdAt":"%s"}' "$1" "$2" "$3"; }
L="$(c Lint COMPLETED SUCCESS)"
ok "StatusContext: failure then success => ok"          "$(pr "[$(sc ci/x FAILURE $T1),$(sc ci/x SUCCESS $T2),$L,$G]" | ev abcdef1)" "ok"
ok "StatusContext: success then failure => refuse"      "$(pr "[$(sc ci/x SUCCESS $T1),$(sc ci/x FAILURE $T2),$L,$G]" | ev abcdef1)" "refuse:failing check(s): ci/x"
ok "different names never mask each other"              "$(pr "[$(ct Lint COMPLETED FAILURE $T1 $T1),$(ct Gate COMPLETED SUCCESS $T2 $T2)]" | ev abcdef1)" "refuse:failing check(s): Lint"
# a path-filtered check is not required, but when it DID run and failed it still refuses
ev3() { python3 -I "$OPS/lib/merge_gate.py" evaluate "$1" "$req3"; }
P="$(c EveryPr COMPLETED SUCCESS),$(c PushFilteredOnly COMPLETED SUCCESS),$(c PushFilteredOnly2 COMPLETED SUCCESS)"
ok "path-filtered check absent => ok (no 180 min wait)" "$(pr "[$P]" | ev3 abcdef1)" "ok"
ok "path-filtered check ran and failed => refuse"       "$(pr "[$P,$(c BlastRadius COMPLETED FAILURE)]" | ev3 abcdef1)" "refuse:failing check(s): BlastRadius"
ok "path-filtered check still running => wait"          "$(pr "[$P,$(c BlastRadius IN_PROGRESS '')]" | ev3 abcdef1)" "wait:not finished: BlastRadius"

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

# the PR 56 shape end to end: two same-name runs, CANCELLED then SUCCESS => merges; the reverse merges nothing
printf '%s' "$(pr "[$(ct Lint COMPLETED CANCELLED $T1 $T1),$(ct Lint COMPLETED SUCCESS $T2 $T2),$G]")" > "$TMP/pr56.json"
printf '%s' "$(pr "[$(ct Lint COMPLETED SUCCESS $T1 $T1),$(ct Lint COMPLETED FAILURE $T2 $T2),$G]")" > "$TMP/pr56rev.json"
ok "driver: cancelled then success merges (exit 0)" "$(run "$TMP/pr56.json" --polls 3)" "0"
ok "  ...and actually ran the merge"                "$([ -f "$TMP/merged" ] && echo yes || echo no)" "yes"
ok "driver: success then failure refuses (exit 1)"  "$(run "$TMP/pr56rev.json" --polls 3)" "1"
ok "  ...merge cmd not run"                         "$([ -f "$TMP/merged" ] && echo yes || echo no)" "no"

# --- I-8: a hands PR (--hands) is refused when a workflow lets PR code reach a secret ---
WFX="$TMP/wfx"; mkdir -p "$WFX"
cat > "$WFX/ci.yml" <<'Y'
name: CI
on:
  pull_request:
    branches: [main]
jobs:
  lint:
    name: Lint
    runs-on: x
    steps:
      - run: echo ${{ secrets.GITHUB_TOKEN }}
  notify:
    name: Notify
    if: github.event_name == 'push' && github.ref == 'refs/heads/main'
    runs-on: x
    steps:
      - run: curl -d ${{ secrets.SLACK_WEBHOOK }} x
Y
ok "exposure: GITHUB_TOKEN and a push-only notify job are not exposure" "$(python3 -I "$OPS/lib/merge_gate.py" secrets-exposure "$WFX")" "[]"
cat > "$WFX/deploy.yml" <<'Y'
on:
  pull_request_target:
jobs:
  preview:
    runs-on: x
    steps:
      - run: deploy
        env:
          CLOUDFLARE_API_TOKEN: ${{ secrets.CLOUDFLARE_API_TOKEN }}
Y
ok "exposure: a secret in a PR-triggered job is named" "$(python3 -I "$OPS/lib/merge_gate.py" secrets-exposure "$WFX")" '["deploy.yml:preview:CLOUDFLARE_API_TOKEN"]'
WFY="$TMP/wfy"; mkdir -p "$WFY"
cat > "$WFY/ci.yml" <<'Y'
on:
  pull_request:
env:
  TOKEN: ${{ secrets.NPM_TOKEN }}
jobs:
  lint:
    name: Lint
    runs-on: x
Y
ok "exposure: a workflow-level env secret counts" "$(python3 -I "$OPS/lib/merge_gate.py" secrets-exposure "$WFY")" '["ci.yml:(workflow env):NPM_TOKEN"]'
# the driver: --hands refuses (exit 2, nothing merged) on exposure; without --hands the same workflows are fine
printf '%s' "$GREEN" > "$TMP/green.json"; rm -f "$TMP/merged"
MERGE_GATE_VIEW_CMD="cat $TMP/green.json" MERGE_GATE_MERGE_CMD="echo merged > $TMP/merged" bash "$OPS/merge-gate.sh" 7 abcdef1 --workflows "$WFX" --interval 0 --polls 1 --hands >"$TMP/out" 2>&1; rc=$?
ok "--hands + exposed secret => refuse (2)" "$rc" "2"
ok "  ...merge cmd not run"                  "$([ -f "$TMP/merged" ] && echo yes || echo no)" "no"
ok "  ...names the secret"                   "$(grep -c CLOUDFLARE_API_TOKEN "$TMP/out")" "1"
cat > "$WFX/ci.yml" <<'Y'
name: CI
on:
  pull_request:
jobs:
  lint:
    name: Lint
    runs-on: x
    steps:
      - run: echo hi
Y
rm "$WFX/deploy.yml"; printf '%s' "$(pr "[$(c Lint COMPLETED SUCCESS)]")" > "$TMP/g1.json"
MERGE_GATE_VIEW_CMD="cat $TMP/g1.json" MERGE_GATE_MERGE_CMD="echo merged > $TMP/merged" bash "$OPS/merge-gate.sh" 7 abcdef1 --workflows "$WFX" --interval 0 --polls 1 --hands >"$TMP/out" 2>&1; rc=$?
ok "--hands with no exposure still merges (0)" "$rc" "0"
echo "---"; echo "merge-gate: $pass passed, $fail failed"; [ "$fail" = 0 ]
