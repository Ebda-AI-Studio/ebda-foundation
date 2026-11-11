#!/usr/bin/env bash
# F-12: every repo the hands may push to must have a ruleset on its default branch: pull request required, required status checks, no force push
# (non_fast_forward), no deletion, and NO bypass actors. The hands never push to a default branch, but a leaked token plus an unprotected branch is
# a direct write to main; this is the fence that makes the standing PAT (or App token) survivable.
#   check-rulesets.sh [--config FILE]     repos = the keys of the hands config (HANDS_CONFIG_JSON or --config / ~/.ebda-os.hands.json)
#   deploy.sh --check                     runs it
# Test seam: GH_BIN (default gh). Exit 0 = every repo protected, 1 = at least one is not (named), 2 = could not read.
set -uo pipefail
GH="${GH_BIN:-gh}"; cfg=""
[ "${1:-}" = "--config" ] && cfg="${2:-}"
if [ -n "$cfg" ]; then json="$(cat "$cfg" 2>/dev/null)" || { echo "check-rulesets: cannot read $cfg" >&2; exit 2; }
elif [ -n "${HANDS_CONFIG_JSON:-}" ]; then json="$HANDS_CONFIG_JSON"
elif [ -f "$HOME/.ebda-os.hands.json" ]; then json="$(cat "$HOME/.ebda-os.hands.json")"
else echo "check-rulesets: no hands config (HANDS_CONFIG_JSON, --config or ~/.ebda-os.hands.json)" >&2; exit 2; fi
repos="$(printf '%s' "$json" | python3 -I -c 'import json,sys; print(" ".join(sorted((json.load(sys.stdin).get("repos") or {}).keys())))')" || { echo "check-rulesets: config is not JSON" >&2; exit 2; }
[ -n "$repos" ] || { echo "check-rulesets: the hands config lists no repos" >&2; exit 2; }
bad=0
for r in $repos; do
  def="$("$GH" api "repos/$r" --jq .default_branch 2>/dev/null)" || { echo "UNKNOWN $r: cannot read the repo (gh auth?)"; bad=1; continue; }
  rs="$("$GH" api "repos/$r/rulesets" 2>/dev/null)" || { echo "UNKNOWN $r: cannot read rulesets"; bad=1; continue; }
  # each ruleset summary lacks its rules; fetch the detail of every active one
  detail="[]"
  for id in $(printf '%s' "$rs" | python3 -I -c 'import json,sys; print(" ".join(str(x["id"]) for x in json.load(sys.stdin) if x.get("enforcement")=="active" and x.get("target")=="branch"))'); do
    d="$("$GH" api "repos/$r/rulesets/$id" 2>/dev/null)" || continue
    detail="$(python3 -I -c 'import json,sys; a=json.loads(sys.argv[1]); a.append(json.loads(sys.argv[2])); print(json.dumps(a))' "$detail" "$d")"
  done
  verdict="$(printf '%s' "$detail" | python3 -I -c '
import json, sys
default = sys.argv[1]
need = {"pull_request", "required_status_checks", "non_fast_forward", "deletion"}
have, bypass = set(), False
for rs in json.load(sys.stdin):
    inc = ((rs.get("conditions") or {}).get("ref_name") or {}).get("include") or []
    if not any(i in ("~DEFAULT_BRANCH", "refs/heads/" + default, "~ALL") for i in inc):
        continue
    have |= {r.get("type") for r in rs.get("rules") or []}
    if rs.get("bypass_actors"):
        bypass = True
missing = sorted(need - have)
print("ok" if not missing and not bypass else "missing: " + ", ".join(missing) + ("; has bypass actors" if bypass else ""))
' "$def")"
  if [ "$verdict" = ok ]; then echo "OK $r ($def)"; else echo "UNPROTECTED $r ($def): $verdict"; bad=1; fi
done
exit "$bad"
