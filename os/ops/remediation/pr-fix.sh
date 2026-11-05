# shellcheck shell=bash
# pr-fix.sh — Class-B code-fix agent: guardrails + self-check + pr_fix.
# Sourceable: NO side effects at source time.

# EXCLUDED-path regex: a touched path matching this is rejected regardless of the
# finding's declared class (second net behind the classifier).
# shellcheck source=lib/os-config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/os-config.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-config.sh" 2>/dev/null || true
command -v os_config_load >/dev/null 2>&1 && os_config_load
_GR_EXCLUDED_RE='(^|[/._-])(auth|session|login|oauth|payment|payments|billing|invoice|checkout|myfatoorah|money|rls|polic(y|ies)|secret|secrets|credentials|deploy|wrangler|railway)($|[^a-z])|\.env|(^|[/._-])migrations?/|schema\.prisma|\.github/workflows/'

HERE_PF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE_PF/ledger.sh" 2>/dev/null || . "$HOME/.claude/scripts/remediation/ledger.sh" 2>/dev/null || true

gr_excluded_path() { printf '%s' "$1" | grep -qiE "$_GR_EXCLUDED_RE"; }

gr_touches_excluded() { # <repo> <base> <head> -> 0 if any changed file is excluded
  local repo="$1" base="$2" head="$3" p
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    gr_excluded_path "$p" && return 0
  done <<EOF
$(git -C "$repo" diff --name-only "$base" "$head")
EOF
  return 1
}

gr_adds_dependency() { # <repo> <base> <head> -> 0 if a dep manifest changed
  git -C "$1" diff --name-only "$2" "$3" \
    | grep -qE '(^|/)(package\.json|package-lock\.json|pnpm-lock\.yaml|yarn\.lock)$'
}

gr_diff_size() { # <repo> <base> <head> -> total added+deleted lines (int)
  git -C "$1" diff --numstat "$2" "$3" | python3 -c '
import sys
t=0
for ln in sys.stdin:
    p=ln.split()
    if len(p)>=2 and p[0].isdigit() and p[1].isdigit():
        t+=int(p[0])+int(p[1])
print(t)'
}

gr_unrelated() { # <repo> <base> <head> <allowed-json> -> 0 if a changed file is NOT allowed
  local repo="$1" base="$2" head="$3" allowed="$4"
  [ -z "$allowed" ] && return 1
  git -C "$repo" diff --name-only "$base" "$head" | python3 -c '
import json,sys
allowed=set(json.loads(sys.argv[1]))
if not allowed: sys.exit(1)          # no constraint
for ln in sys.stdin:
    f=ln.strip()
    if f and f not in allowed: sys.exit(0)   # found an unrelated file
sys.exit(1)' "$allowed"
}

guardrail_verdict() { # <repo> <base> <head> <finding-json> -> REJECT ... | OVERSIZE | OK
  local repo="$1" base="$2" head="$3" finding="$4" allowed sz
  gr_touches_excluded "$repo" "$base" "$head" && { echo "REJECT excluded-path"; return; }
  gr_adds_dependency  "$repo" "$base" "$head" && { echo "REJECT dependency-add"; return; }
  allowed="$(printf '%s' "$finding" | python3 -c 'import json,sys
try: print(json.dumps(json.load(sys.stdin).get("files") or []))
except Exception: print("[]")')"
  gr_unrelated "$repo" "$base" "$head" "$allowed" && { echo "REJECT unrelated-file"; return; }
  sz="$(gr_diff_size "$repo" "$base" "$head")"
  [ "${sz:-0}" -gt 150 ] && { echo OVERSIZE; return; }
  echo OK
}

_have_npm_script() { # <repo> <name>
  [ -f "$1/package.json" ] || return 1
  python3 -c 'import json,sys
try: sys.exit(0 if sys.argv[2] in (json.load(open(sys.argv[1]+"/package.json")).get("scripts") or {}) else 1)
except Exception: sys.exit(1)' "$1" "$2"
}

self_check() { # <repo> -> 0 all present checks pass, 1 on first failure
  local repo="$1" name
  [ -f "$repo/package.json" ] || return 0
  for name in lint typecheck; do
    if _have_npm_script "$repo" "$name"; then
      ( cd "$repo" && npm run "$name" ) >/dev/null 2>&1 || return 1
    fi
  done
  # touched-file tests: best-effort, only if a test script exists.
  if _have_npm_script "$repo" test; then
    ( cd "$repo" && npm test -- --passWithNoTests ) >/dev/null 2>&1 || return 1
  fi
  return 0
}

_pf_base() { # <repo> -> origin default branch (fallback main)
  local b; b="$(git -C "$1" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')"
  [ -n "$b" ] && printf '%s' "$b" || printf 'main'
}

_pf_prompt() { # <class> <desc>
  cat <<EOF
You are the Force AI OS Class-B remediation agent fixing ONE finding in this repo.
FIRST read the memory-first layers: graphify-out/GRAPH_REPORT.md, the relevant scoped
feedback-*.md / project-*.md, and MEMORY.md. Follow this repo's CLAUDE.md and the global
15 code-quality non-negotiables.
Finding class: $1
Finding: $2
HARD CONTRACT (a violation gets your fix discarded, no PR):
 - Change ONLY files needed for THIS finding.
 - NEVER touch auth/session, money/payment, RLS/policy, DB migrations, secrets/.env, or
   deploy config — even if the finding looks like plain code.
 - Add NO new dependencies (no package.json / lockfile changes).
 - Keep the diff <= 150 changed lines.
Make the minimal surgical fix now — edit only the files needed, nothing else.
EOF
}

pr_fix() { # <finding-json> <repo-path> -> one result token
  local finding="$1" repo="$2"
  [ "${REMEDIATE_DRYRUN:-0}" = "1" ] && { echo DRY; return 0; }
  local claude_cmd="${CLAUDE_CMD:-claude}" gh_cmd="${GH_CMD:-gh}"
  local notify="${REMEDIATE_NOTIFY:-$HERE_PF/../notify.sh}"
  local cls desc files base br origbr verdict pr
  cls="$(printf '%s' "$finding"  | python3 -c 'import json,sys;print(json.load(sys.stdin).get("class",""))')"
  desc="$(printf '%s' "$finding" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get("desc") or d.get("class",""))')"
  origbr="$(git -C "$repo" symbolic-ref --quiet --short HEAD 2>/dev/null || echo main)"
  base="$(_pf_base "$repo")"
  local reponame slug
  reponame="$(printf '%s' "$finding" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("repo",""))')"
  [ -n "$reponame" ] || reponame="$(basename "$repo")"
  slug="$OS_ORG/$reponame"
  git -C "$repo" fetch -q origin 2>/dev/null || true
  br="remediate/${cls}-$(date +%s)"
  local baseref="origin/$base"
  git -C "$repo" rev-parse --verify -q "$baseref" >/dev/null 2>&1 || baseref="$origbr"
  git -C "$repo" checkout -q -b "$br" "$baseref" || { echo "REJECT branch"; stall_bump "$cls"; return 1; }
  # cleanup: always return the repo to its original branch
  trap 'git -C "'"$repo"'" checkout -q "'"$origbr"'" 2>/dev/null; trap - RETURN' RETURN

  # dispatch the agent (cwd=repo so it inherits CLAUDE.md + memory); nvm node 24 on PATH
  # (Homebrew node 25 crashes `claude -p`). Scope tools to read/edit only — the diff
  # guardrail cannot see non-diff side effects, so the agent must not run Bash/network.
  local _d node24bin=""
  for _d in "$HOME"/.nvm/versions/node/v24*/bin; do [ -x "$_d/node" ] && node24bin="$_d" && break; done
  ( cd "$repo" && PATH="${node24bin:+$node24bin:}$PATH" \
      "$claude_cmd" -p --model sonnet --allowedTools "Read,Edit,Grep,Write" \
      "$(_pf_prompt "$cls" "$desc")" >/dev/null 2>&1 ) || true

  # Stage EXACTLY the agent's changes by explicit path — never blanket `git add -A`
  # (global rule: no mass-staging in an autonomous agent inside a production repo).
  # The branch was cut from a clean root-on-main, so every porcelain entry is the
  # agent's own change. Excluded/unrelated paths are deliberately staged too, so the
  # guardrail below can SEE and REJECT them. NUL-safe; handles rename/copy source fields.
  local _paths=() _f _skip=0 _st _p
  while IFS= read -r -d '' _f; do
    if [ "$_skip" = "1" ]; then _skip=0; continue; fi   # rename/copy SOURCE field — skip
    _st="${_f:0:2}"; _p="${_f:3}"
    _paths+=("$_p")
    case "$_st" in R*|C*) _skip=1;; esac
  done < <(git -C "$repo" status -z --porcelain --untracked-files=all)
  [ "${#_paths[@]}" -eq 0 ] && { echo NOFIX; stall_bump "$cls"; return 0; }
  git -C "$repo" add -- "${_paths[@]}"
  if git -C "$repo" diff --cached --quiet; then echo NOFIX; stall_bump "$cls"; return 0; fi
  git -C "$repo" commit -q -m "fix(remediation): $cls"

  verdict="$(guardrail_verdict "$repo" "origin/$base" HEAD "$finding")"
  case "$verdict" in
    REJECT*)   echo "$verdict"; stall_bump "$cls"; return 0 ;;
  esac
  if ! self_check "$repo"; then echo SELFCHECK-FAIL; stall_bump "$cls"; return 0; fi

  git -C "$repo" push -q -u origin "$br" || { echo "REJECT push"; stall_bump "$cls"; return 1; }
  pr="$("$gh_cmd" pr create --repo "$slug" --head "$br" \
        --title "remediation: $cls" \
        --body "Automated Class-B $cls fix. Gated by CI + blast-radius + AI review score." \
        2>/dev/null | grep -oE '[0-9]+$')"
  [ -n "$pr" ] || { echo "REJECT pr-create"; stall_bump "$cls"; return 0; }
  local item; item="$(python3 -c 'import json,sys;print(json.dumps({"pr":sys.argv[1],"slug":sys.argv[2],"branch":sys.argv[3],"repo":sys.argv[4]},separators=(",",":")))' \
        "$pr" "$slug" "$br" "$repo")"
  if [ "$verdict" = "OVERSIZE" ]; then
    pending_add "$pr" "$item"
    "$notify" "Remediation — large fix needs approval" \
      "Large fix ($cls) in $reponame, PR #$pr — reply \`process it #$pr\` to approve." >/dev/null 2>&1 || true
    echo "PENDING pr#$pr"
  else
    queue_add "$item"
    echo "QUEUED pr#$pr"
  fi
}