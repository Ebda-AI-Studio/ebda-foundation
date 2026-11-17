#!/usr/bin/env bash
# wt_candidates: the hygiene sweep must never treat a tracked __tests__/__mocks__/babel__core dir INSIDE a repo as an orphan
# worktree (2026-10-30: it rm -rf'd msg-guard-1/{backend,frontend}/__tests__). Every case has its NEGATIVE (the old glob).
# Run: bash ops/lib/__tests__/wt-candidates.test.sh
set -uo pipefail
OPS="$(cd "$(dirname "$0")/../.." && pwd)"
. "$OPS/lib/wt-safety.sh"
_pass=0; _fail=0
ok() { echo "PASS: $1"; _pass=$((_pass+1)); }
no() { echo "FAIL: $1"; _fail=$((_fail+1)); }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
R="$T/_worktrees"
mk() { mkdir -p "$R/$1"; }
# a live worktree with an ordinary name (EnterWorktree / Agent isolation) holding the tracked test dirs
mk msg-guard-1/frontend/__tests__; mk msg-guard-1/backend/__tests__; mk msg-guard-1/backend/node_modules/@types/babel__core
mk msg-guard-1/backend/node_modules/jsx-ast-utils/__tests__; mk msg-guard-1/backend/third/__snapshots__; echo "gitdir: x" > "$R/msg-guard-1/.git"
# a live worktree named by the convention, an orphan one, and nested containers
mk Whisky-11/clients/acme-client/acme-client-app__feat-x; echo "gitdir: x" > "$R/Whisky-11/clients/acme-client/acme-client-app__feat-x/.git"
mk Whisky-11/clients/acme-client/acme-client-app__feat-x/src/__tests__
mk Whisky-11/clients/acme-client/acme-client-app__crashed
# an un-registered dir that is NOT a worktree but has no .git and lives under a container (a plain tests dir at depth)
mk scratch/pkg/__mocks__
OUT="$(wt_candidates "$R" | sed "s#^$R/##" | sort)"
EXP="$(printf '%s\n' 'Whisky-11/clients/acme-client/acme-client-app__crashed' 'Whisky-11/clients/acme-client/acme-client-app__feat-x' | sort)"
[ "$OUT" = "$EXP" ] && ok "only <repo>__<slug> dirs outside any repo are candidates" || { no "candidates differ"; echo "got:"; echo "$OUT"; }
grep -q "__tests__" <<<"$OUT" && no "a __tests__ dir became a candidate" || ok "no __tests__ / __mocks__ / __snapshots__ dir is a candidate"
grep -q "babel__core" <<<"$OUT" && no "a node_modules package dir became a candidate" || ok "a node_modules package dir (babel__core) is never a candidate"
# NEGATIVE: the old glob does select them (the guard is not vacuous)
OLD="$(find "$R" -mindepth 1 -maxdepth 6 -type d -name '*__*' -prune -print | sed "s#^$R/##" | sort)"
grep -q "msg-guard-1/frontend/__tests__" <<<"$OLD" && ok "NEGATIVE: the old find glob selected msg-guard-1/frontend/__tests__ (the bug)" || no "the old glob did not reproduce the bug"
grep -q "msg-guard-1/backend/node_modules/@types/babel__core" <<<"$OLD" && ok "NEGATIVE: the old glob also selected node_modules/@types/babel__core" || no "old glob missed babel__core"
echo "passed=$_pass failed=$_fail"; [ "$_fail" -eq 0 ]
