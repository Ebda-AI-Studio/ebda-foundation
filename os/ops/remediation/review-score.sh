# shellcheck shell=bash
# CLAUDE_BIN lets a test point this at a stub. Without it the model call is
# untestable offline, which is why none of the OS's 17 model-calling scripts
# had a single behavioural test. Defaults to the real CLI.
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
# review_score <pr> <slug> -> {"score":N,"reasoning":"..."}  (fail-closed to 0)
review_score() {
  local pr="$1" slug="$2" diff prompt raw
  diff="$(gh pr diff "$pr" --repo "$slug" 2>/dev/null | head -c 60000)" || diff=""
  prompt="You are a release gatekeeper. Rate this PR's PRODUCTION-SAFETY 0-100 = confidence it will NOT break production (100 = certainly safe, trivial; below 80 = any real risk). Consider: does it touch money/auth/RLS/migrations/secrets/deploy config? runtime behavior change? test coverage? Respond with ONLY compact JSON: {\"score\":<int 0-100>,\"reasoning\":\"<one sentence>\"}. PR diff follows:\n\n$diff"
  raw="$(printf '%s' "$prompt" | "$CLAUDE_BIN" -p 2>/dev/null)" || raw=""
  # extract + validate the JSON object; clamp score; fail-closed on anything odd.
  # NOTE: a heredoc on the same command as a pipe overrides the pipe's stdin in
  # POSIX shells, so the python script is captured into a variable first and
  # passed via `-c`, leaving stdin free to carry $raw through the pipe.
  local pyscript
  read -r -d '' pyscript <<'PY'
import json,sys,re
raw=sys.stdin.read(); m=re.search(r'\{.*\}', raw, re.S)
if not m: print('{"score":0,"reasoning":"review failed: no json"}'); sys.exit(0)
o=json.loads(m.group(0)); s=int(o.get("score",0)); s=max(0,min(100,s))
print(json.dumps({"score":s,"reasoning":str(o.get("reasoning",""))[:300]}, separators=(",", ":")))
PY
  printf '%s' "$raw" | python3 -c "$pyscript" 2>/dev/null || echo '{"score":0,"reasoning":"review failed: parse"}'
}