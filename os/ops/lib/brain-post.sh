# shellcheck shell=bash
# lib/brain-post.sh - hand findings to the brain instead of messaging anyone (act-not-ping).
#
#   . lib/os-config.sh && os_config_load && . lib/brain-post.sh
#   brain_post_findings FILE.json          # FILE holds a JSON array of brain findings (see cloud/brain/src/findings.ts)
#   brain_dream_to_findings FILE.json      # dream-findings.json ({findings:[...]}) -> brain findings array on stdout
#   brain_spool_drain                      # re-post everything spooled earlier (called by brain_post_findings first)
#
# Where it goes: POST $OS_BRAIN_URL/findings with "Authorization: Bearer $INGEST_TOKEN" (both read from the services env
# $OS_SERVICES_ENV, never from git). Brain URL or token unset, or the POST fails: every finding is appended, one JSON object
# per line, to $OS_STATE_DIR/brain-spool.ndjson for the brain to pick up later. Nothing here sends a message.
# The brain dedupes by fingerprint (source|kind|key), so re-posting a spooled finding is safe.
# Returns 0 on "delivered", 10 on "spooled". DRY_RUN=1 prints what would be posted and touches nothing.

_brain_env() {
  if [ -f "${OS_SERVICES_ENV:-}" ]; then
    local _l
    for _k in OS_BRAIN_URL INGEST_TOKEN; do
      [ -n "${!_k:-}" ] && continue
      _l="$(grep -E "^${_k}=" "$OS_SERVICES_ENV" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"'"'")"
      [ -n "$_l" ] && export "$_k=$_l"
    done
  fi
  return 0
}

brain_spool_file() { printf '%s/brain-spool.ndjson' "${OS_STATE_DIR:-$HOME/.whisky-os-state}"; }

# brain_dream_to_findings FILE - map the dream cycle's findings to the brain's Finding shape.
brain_dream_to_findings() {
  python3 -I - "${1:?findings file}" <<'PY'
import json, sys, hashlib
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("[]"); sys.exit(0)
sev = {"critical": "P1", "high": "P2"}
out = []
for f in (d.get("findings") or []):
    repo = str(f.get("repo") or "")
    cls = str(f.get("class") or "finding")
    title = str(f.get("title") or cls)[:500]
    key = "%s|%s|%s|%s" % (repo, cls, f.get("file") or "", hashlib.sha256(title.encode()).hexdigest()[:12])
    o = {"source": "dream", "kind": cls[:80], "key": key[:500], "title": title,
         "severity": sev.get(str(f.get("severity")), "P3"),
         "detail": {k: f.get(k) for k in ("file", "line", "detail", "fix", "autofixable") if f.get(k) not in (None, "")}}
    if repo and repo != "__memory__" and "/" in repo:
        o["repo"] = repo
    out.append(o)
print(json.dumps(out))
PY
}

_brain_spool_append() { # stdin: findings array; appends one object per line
  local sp; sp="$(brain_spool_file)"; mkdir -p "$(dirname "$sp")" 2>/dev/null
  python3 -I -c 'import json,sys
for o in json.load(sys.stdin): print(json.dumps(o))' >> "$sp"
}

_brain_post_raw() { # $1 file -> 0 delivered, 1 failed/unconfigured
  [ -n "${OS_BRAIN_URL:-}" ] && [ -n "${INGEST_TOKEN:-}" ] || return 1
  curl -fsS -m 30 -o /dev/null -X POST "${OS_BRAIN_URL%/}/findings" \
    -H "Authorization: Bearer $INGEST_TOKEN" -H 'content-type: application/json' --data-binary "@$1" 2>/dev/null
}

brain_post_findings() {
  local f="${1:?findings array file}" n
  _brain_env
  n="$(python3 -I -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$f" 2>/dev/null || echo 0)"
  [ "$n" -gt 0 ] || return 0
  if [ "${DRY_RUN:-0}" = 1 ]; then echo "[brain-post] DRY: would post $n finding(s) to ${OS_BRAIN_URL:-<spool: no brain url>}"; return 0; fi
  brain_spool_drain
  # the endpoint takes at most 100 per request
  local chunk i=0 rc=0 tmp
  tmp="$(mktemp)"
  while [ "$i" -lt "$n" ]; do
    python3 -I -c 'import json,sys; json.dump(json.load(open(sys.argv[1]))[int(sys.argv[2]):int(sys.argv[2])+100], open(sys.argv[3],"w"))' "$f" "$i" "$tmp"
    if _brain_post_raw "$tmp"; then :; else _brain_spool_append < "$tmp"; rc=10; fi
    i=$((i+100))
  done
  rm -f "$tmp"
  [ "$rc" = 10 ] && echo "[brain-post] brain unreachable or not configured: spooled to $(brain_spool_file)" >&2
  return "$rc"
}

brain_spool_drain() {
  local sp tmp; sp="$(brain_spool_file)"
  [ -s "$sp" ] || return 0
  _brain_env
  [ -n "${OS_BRAIN_URL:-}" ] && [ -n "${INGEST_TOKEN:-}" ] || return 0
  tmp="$(mktemp)"
  python3 -I -c 'import json,sys
rows=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]
json.dump(rows[:100], open(sys.argv[2],"w"))
open(sys.argv[1]+".rest","w").write("".join(json.dumps(r)+"\n" for r in rows[100:]))' "$sp" "$tmp"
  if _brain_post_raw "$tmp"; then mv -f "$sp.rest" "$sp"; [ -s "$sp" ] && brain_spool_drain; else rm -f "$sp.rest"; fi
  rm -f "$tmp"
  return 0
}
