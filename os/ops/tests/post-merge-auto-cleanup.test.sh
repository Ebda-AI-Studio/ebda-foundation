#!/usr/bin/env bash
# hooks/post-merge-auto-cleanup.sh must fire workspace-hygiene.sh --repo/--skip after a REAL
# `gh pr merge`, and ONLY then. Why: a false positive deletes nothing (hygiene has its own
# clean+merged gates) but a false negative silently restores the old "agent must remember" state,
# and a hook that blocks or fails would break every Bash call. So: positives, the near-misses
# (--auto, `gh pr list`, the words inside a quoted commit message, non-Bash, bad JSON), and
# always-exit-0 are all asserted.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/../hooks/post-merge-auto-cleanup.sh"
pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1 — got '$2' want '$3'"; fail=$((fail+1)); fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"
ARGS="$TMP/args.txt"
# stub hygiene bin: records its argv (one per line) — stands in for the detached sweep
cat > "$TMP/hygiene-stub.sh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$ARGS"
STUB
export POST_MERGE_HYGIENE_BIN="$TMP/hygiene-stub.sh"

# a git dir whose origin is github (ssh form) and one in the worktree forest
REPO="$TMP/repo"; git init -q "$REPO"; git -C "$REPO" remote add origin git@github.com:acme/widgets.git
WTD="$HOME/Desktop/projects/_worktrees/acme/widgets__feat-x"; mkdir -p "$WTD"; git init -q "$WTD"
git -C "$WTD" remote add origin https://github.com/Acme/Widgets.git

payload() {  # $1=tool_name $2=command $3=cwd
  python3 -c 'import json,sys; print(json.dumps({"tool_name":sys.argv[1],"tool_input":{"command":sys.argv[2]},"cwd":sys.argv[3]}))' "$1" "$2" "$3"
}
run() {  # prints hook stdout; waits for the detached stub
  rm -f "$ARGS"
  OUT="$(printf '%s' "$1" | bash "$HOOK" 2>/dev/null)"; RC=$?
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -s "$ARGS" ] && break; sleep 0.1; done
}
fired() { [ -s "$ARGS" ] && echo yes || echo no; }

# --- positives ---
run "$(payload Bash 'gh pr merge 12 --squash' "$REPO")"
ok "plain merge fires" "$(fired)" "yes"
ok "repo derived from cwd ssh remote" "$(sed -n 2p "$ARGS")" "acme/widgets"
ok "exit 0" "$RC" "0"
ok "skip = cwd toplevel" "$(sed -n 4p "$ARGS")" "$(git -C "$REPO" rev-parse --show-toplevel)"
ok "stdout is valid JSON hookSpecificOutput" "$(printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin)["hookSpecificOutput"]; print(d["hookEventName"])')" "PostToolUse"
ok "context names the repo" "$(printf '%s' "$OUT" | python3 -c 'import json,sys; print("acme/widgets" in json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])')" "True"
ok "no 'kept' sentence outside _worktrees" "$(printf '%s' "$OUT" | grep -c 'is kept')" "0"

run "$(payload Bash 'gh pr merge 12 -R foo/bar --squash' "$REPO")"
ok "-R form" "$(sed -n 2p "$ARGS")" "foo/bar"
run "$(payload Bash 'gh pr merge 12 --repo foo/baz' "$REPO")"
ok "--repo form" "$(sed -n 2p "$ARGS")" "foo/baz"
run "$(payload Bash 'gh pr merge 12 --repo=foo/qux' "$REPO")"
ok "--repo= form" "$(sed -n 2p "$ARGS")" "foo/qux"
run "$(payload Bash 'cd /tmp && gh pr merge 12 --squash' "$REPO")"
ok "merge as a later segment fires" "$(fired)" "yes"

run "$(payload Bash 'gh pr merge 3 --squash' "$WTD")"
ok "https remote + .git stripped" "$(sed -n 2p "$ARGS")" "Acme/Widgets"
ok "skip is the session worktree" "$(sed -n 4p "$ARGS")" "$(git -C "$WTD" rev-parse --show-toplevel)"
ok "context says the session worktree is kept" "$(printf '%s' "$OUT" | grep -c 'is kept')" "1"

# --- negatives (each must NOT fire) ---
run "$(payload Bash 'gh pr merge 12 --auto --squash' "$REPO")";  ok "--auto does not fire" "$(fired)" "no"
run "$(payload Bash 'gh pr merge --help' "$REPO")";              ok "--help does not fire" "$(fired)" "no"
run "$(payload Bash 'gh pr list --state merged' "$REPO")";       ok "gh pr list does not fire" "$(fired)" "no"
run "$(payload Bash 'git commit -m "gh pr merge"' "$REPO")";     ok "quoted string is not a command" "$(fired)" "no"
run "$(payload Read 'gh pr merge 12' "$REPO")";                  ok "non-Bash tool does not fire" "$(fired)" "no"
run 'this is { not json';                                        ok "unparseable JSON does not fire" "$(fired)" "no"
ok "unparseable JSON still exits 0" "$RC" "0"
NOREPO="$TMP/plain"; mkdir -p "$NOREPO"
run "$(payload Bash 'gh pr merge 12' "$NOREPO")";                ok "no derivable repo: silent, no fire" "$(fired)" "no"
ok "no derivable repo: no stdout" "$OUT" ""

# --- missing hygiene script: note on stderr, exit 0, nothing printed ---
ERR="$(printf '%s' "$(payload Bash 'gh pr merge 1' "$REPO")" | POST_MERGE_HYGIENE_BIN="$TMP/nope.sh" bash "$HOOK" 2>&1 >/dev/null)"; rc=$?
ok "missing hygiene script exits 0" "$rc" "0"
ok "missing hygiene script notes on stderr" "$(printf '%s' "$ERR" | grep -c 'not found')" "1"

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
