#!/usr/bin/env bash
# ============================================================
# Ebda AI OS - dream-scan.sh   (dream phase SCAN: find what to improve in the Ebda products)
#
# Targets (Ebda-only, Ahmad 2026-11-06) come from the per-machine ~/.ebda-os.local.json list `dream_products`, one item per product:
#     name|/abs/path/to/checkout|https://live.url|owner/name     (the URL may be empty; owner/name is the GitHub repo the hands work on: without
#     it the brain cannot hand a finding to the hands and files it in the digest, so a missing one is reported loudly)
# Repos whose owner is one of OS_BILLED_ORGS are already covered by the brain's advisory + CI watchers, so the scan SKIPS npm audit and
# the last-CI check for them (one issue raised by two sources would become two jobs and two PRs).
# Per product, cheap checks only (no GitHub Actions minutes, no heavy browser):
#   deps      lockfile older than package.json (lockfile-drift); `npm audit --json` high/critical (dependency-advisory)
#   tests     source files no test file mentions (kind test, up to 5, file:1); last CI run on the repo failing (failing-gate, read
#             through `gh run list`, an API read)
#   live      fetch + timing: slow response (perf), missing <title> / meta description / lang / viewport / h1 / img alt, robots.txt
#             and sitemap.xml missing (seo, a11y)
# Output: $OS_STATE_DIR/dream-findings.json  {"findings":[{repo?, class, severity, file, line, title, detail, fix, key, product,
# evidence, autofixable}]} (always written, possibly empty), and one line per finding appended to $OS_STATE_DIR/dream-history.ndjson
# for dream-research.sh. Keys are stable (product:check:subject), so a re-sighting dedupes at the brain.
# Exit 0 = scan ran. Exit 3 = no dream_products configured (loud: a scan with no targets must not look like "all clean").
# Test hooks: DREAM_SCAN_AUDIT_JSON (npm audit output file), DREAM_SCAN_CI_JSON (gh run list output file),
#             DREAM_SCAN_NO_NET=1 (skip npm audit and gh), DREAM_SCAN_SLOW_S (default 1.5).
# Usage: dream-scan.sh [--deep]     (deep is accepted; the checks are the same today)
# ============================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/os-config.sh
. "$HERE/lib/os-config.sh" 2>/dev/null || . "$HOME/.claude/scripts/lib/os-config.sh" 2>/dev/null || true
command -v os_config_load >/dev/null 2>&1 && os_config_load
export PATH="/opt/homebrew/bin:/usr/bin:/bin:$PATH"
DRY_RUN="${DRY_RUN:-0}"
STATE="$OS_STATE_DIR"; mkdir -p "$STATE"
OUT="$STATE/dream-findings.json"; HIST="$STATE/dream-history.ndjson"
SLOW="${DREAM_SCAN_SLOW_S:-1.5}"
_log() { printf '[dream-scan] %s\n' "$*" >&2; }

targets="$(os_local_list dream_products 2>/dev/null)"
if [ -z "$targets" ]; then
  _log "NO TARGETS: dream_products is empty or missing in the local config (~/.ebda-os.local.json). The scan did NOT run; this is not 'all clean'."
  exit 3
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
: > "$TMP/f.ndjson"
# emit <product> <class> <severity> <key> <title> <file> <line> <evidence> <fix> <autofixable>
emit() {
  python3 -I -c '
import json, sys
import os
p, cls, sev, key, title, file, line, ev, fix, auto = sys.argv[1:11]
print(json.dumps({"repo": os.environ.get("DREAM_REPO", ""), "product": p, "class": cls, "severity": sev, "key": p + ":" + key, "title": ("[" + p + "] " + title)[:480],
                  "file": file, "line": int(line or 0), "evidence": ev, "detail": ev, "fix": fix, "autofixable": auto == "true"}))' "$@" >> "$TMP/f.ndjson"
}

while IFS='|' read -r name path url repo; do
  [ -n "$name" ] && [ -n "$path" ] || continue
  export DREAM_REPO="${repo:-}"
  # the brain already covers repos in its orgs (Dependabot alerts + CI webhooks): skip the duplicate sources for them
  covered=0; case "${repo:-}" in */*) for _o in ${OS_BILLED_ORGS:-}; do [ "${repo%%/*}" = "$_o" ] && covered=1; done ;; esac
  [ -n "${repo:-}" ] || _log "WARNING: $name has no owner/name in dream_products; its findings go to the digest only (the hands cannot work on a repo they are not told)"
  if [ ! -d "$path" ]; then emit "$name" scan-target-missing low "target-missing" "checkout not found: $path" "" 0 "path $path does not exist" "fix the dream_products entry" false; continue; fi
  _log "scanning $name"

  # ---- deps ----
  if [ -f "$path/package.json" ]; then
    if [ -f "$path/package-lock.json" ]; then
      pj="$(git -C "$path" log -1 --format=%ct -- package.json 2>/dev/null)"; lk="$(git -C "$path" log -1 --format=%ct -- package-lock.json 2>/dev/null)"
      if [ -n "$pj" ] && [ -n "$lk" ] && [ "$pj" -gt "$lk" ]; then
        emit "$name" lockfile-drift P3 "lockfile-drift" "package.json changed after package-lock.json" "package-lock.json" 1 "package.json last commit $pj > package-lock.json last commit $lk" "regenerate the lockfile" true
      fi
    else
      emit "$name" lockfile-drift P3 "lockfile-missing" "no package-lock.json" "package.json" 1 "package.json present, package-lock.json absent" "commit a lockfile" true
    fi
    aj="${DREAM_SCAN_AUDIT_JSON:-}"
    [ "$covered" = 1 ] && aj=""
    if [ "$covered" != 1 ] && [ -z "$aj" ] && [ "${DREAM_SCAN_NO_NET:-0}" != 1 ] && [ -f "$path/package-lock.json" ] && command -v npm >/dev/null 2>&1; then
      aj="$TMP/audit-$name.json"; ( cd "$path" && npm audit --json > "$aj" 2>/dev/null ) || true
    fi
    if [ -n "$aj" ] && [ -s "$aj" ]; then
      python3 -I - "$aj" "$name" <<'PY' | while IFS= read -r l; do eval "emit \"\$name\" $l"; done
import json, sys, shlex
try: d = json.load(open(sys.argv[1]))
except Exception: sys.exit(0)
for pkg, v in sorted((d.get("vulnerabilities") or {}).items()):
    sev = v.get("severity")
    if sev not in ("high", "critical"): continue
    via = [x for x in (v.get("via") or []) if isinstance(x, dict)]
    t = via[0].get("title") if via else "vulnerable dependency chain"
    ev = "package-lock.json: %s %s (%s)%s" % (pkg, v.get("range", ""), sev, (" " + via[0].get("url")) if via and via[0].get("url") else "")
    print(" ".join(shlex.quote(x) for x in ["dependency-advisory", "P1" if sev == "critical" else "P2", "audit:%s:%s" % (pkg, sev), "npm audit %s: %s in %s" % (sev, t, pkg), "package-lock.json", "1", ev, "bump %s" % pkg, "true" if v.get("fixAvailable") else "false"]))
PY
    fi
  fi

  # ---- untested source paths (cheap heuristic: no test/spec file mentions the module's basename) ----
  untested="$(cd "$path" && find src lib app -type f \( -name '*.ts' -o -name '*.tsx' -o -name '*.js' -o -name '*.mjs' \) \
      ! -name '*.d.ts' ! -name '*.test.*' ! -name '*.spec.*' ! -name 'index.*' ! -path '*/node_modules/*' ! -path '*/.next/*' ! -path '*/dist/*' 2>/dev/null \
    | while IFS= read -r f; do b="$(basename "$f")"; b="${b%.*}"
        if ! grep -q . < <(find . \( -path ./node_modules -o -path ./.git -o -path ./dist -o -path ./.next \) -prune -o -type f \( -name "$b.test.*" -o -name "$b.spec.*" -o -name "$b-*.test.*" \) -print 2>/dev/null); then
          printf '%s\t%s\n' "$(wc -c < "$f" | tr -d ' ')" "$f"; fi; done | sort -rn | head -5 | cut -f2)"
  while IFS= read -r f; do [ -n "$f" ] || continue
    emit "$name" test P3 "untested:$f" "no test file for $f" "$f" 1 "$f:1 has no *.test.* / *.spec.* named after it" "add a unit test" false
  done <<< "$untested"

  # ---- last CI result (API read; no Actions minutes) ----
  cj="${DREAM_SCAN_CI_JSON:-}"
  [ "$covered" = 1 ] && cj=""
  if [ "$covered" != 1 ] && [ -z "$cj" ] && [ "${DREAM_SCAN_NO_NET:-0}" != 1 ] && command -v gh >/dev/null 2>&1; then
    slug="$(git -C "$path" remote get-url origin 2>/dev/null | sed -E 's#^.*github.com[:/]##; s#\.git$##')"
    if [ -n "$slug" ]; then cj="$TMP/ci-$name.json"; gh run list -R "$slug" -L 10 --json name,conclusion,url,headBranch > "$cj" 2>/dev/null || cj=""; fi
  fi
  if [ -n "$cj" ] && [ -s "$cj" ]; then
    python3 -I - "$cj" <<'PY' | while IFS= read -r l; do eval "emit \"\$name\" $l"; done
import json, sys, shlex
try: runs = json.load(open(sys.argv[1]))
except Exception: sys.exit(0)
seen = set()
for r in runs:
    n = r.get("name") or "ci"
    if n in seen: continue
    seen.add(n)                       # the latest run of each workflow decides
    if r.get("conclusion") == "failure":
        print(" ".join(shlex.quote(x) for x in ["failing-gate", "P2", "ci:" + n, "latest %s run is failing" % n, "", "0", "%s on %s" % (r.get("url", ""), r.get("headBranch", "")), "fix the failing gate", "false"]))
PY
  fi

  # ---- live probes ----
  if [ -n "${url:-}" ]; then
    curl -sS -L -m 20 -o "$TMP/page.html" -w '%{http_code} %{time_total}' "$url" > "$TMP/curl.out" 2>"$TMP/curl.err"; crc=$?
    read -r code secs < "$TMP/curl.out" 2>/dev/null || { code=000; secs=0; }
    if [ "$crc" != 0 ] || { case "$url" in file://*) false ;; *) [ "${code:-000}" -ge 400 ] 2>/dev/null || [ "${code:-000}" = 000 ] ;; esac; }; then
      emit "$name" live-unreachable P2 "live:unreachable" "live URL not healthy: $url" "" 0 "$url -> HTTP ${code:-000} (curl rc $crc)" "check the deploy" false
    else
      if awk "BEGIN{exit !($secs > $SLOW)}"; then
        emit "$name" perf P3 "perf:response-time" "slow response from $url" "" 0 "$url took ${secs}s (threshold ${SLOW}s)" "cache / reduce server work" false
      fi
      python3 -I - "$TMP/page.html" <<'PY' | while IFS= read -r l; do eval "emit \"\$name\" $l"; done
import re, sys, shlex
h = open(sys.argv[1], errors="ignore").read()
def out(cls, sev, key, title, ev, fix):
    print(" ".join(shlex.quote(x) for x in [cls, sev, key, title, "", "0", ev, fix, "false"]))
m = re.search(r"<title[^>]*>(.*?)</title>", h, re.I | re.S)
if not m or not m.group(1).strip(): out("seo", "P3", "seo:title", "page has no <title>", "no non-empty <title> in the fetched HTML", "add a descriptive title")
if not re.search(r'<meta[^>]+name=["\']description["\'][^>]+content=["\'][^"\']+', h, re.I): out("seo", "P3", "seo:description", "no meta description", "no <meta name=description content=...>", "add a meta description")
if not re.search(r"<html[^>]+\blang=", h, re.I): out("a11y", "P3", "a11y:lang", "<html> has no lang attribute", "<html> without lang", "set lang (ar/en)")
if not re.search(r'<meta[^>]+name=["\']viewport["\']', h, re.I): out("a11y", "P3", "a11y:viewport", "no viewport meta", "no <meta name=viewport>", "add the viewport meta")
if not re.search(r"<h1[\s>]", h, re.I): out("seo", "P3", "seo:h1", "page has no <h1>", "no <h1> in the fetched HTML", "add one h1")
noalt = [t for t in re.findall(r"<img\b[^>]*>", h, re.I) if not re.search(r"\balt=", t, re.I)]
if noalt: out("a11y", "P3", "a11y:img-alt", "%d image(s) without alt text" % len(noalt), "%d <img> tags without alt, first: %s" % (len(noalt), noalt[0][:120]), "add alt text")
PY
      case "$url" in http*)
        origin="$(printf '%s' "$url" | sed -E 's#^(https?://[^/]+).*#\1#')"
        for f in robots.txt sitemap.xml; do
          c="$(curl -s -o /dev/null -m 10 -w '%{http_code}' "$origin/$f" 2>/dev/null)"
          [ "${c:-000}" = 200 ] || emit "$name" seo P3 "seo:$f" "$f missing on the live site" "" 0 "$origin/$f -> HTTP ${c:-000}" "serve $f" false
        done ;;
      esac
    fi
  fi
done <<< "$targets"

python3 -I - "$TMP/f.ndjson" "$OUT" "$HIST" "$DRY_RUN" <<'PY'
import json, sys, datetime
src, out, hist, dry = sys.argv[1:5]
fs = [json.loads(l) for l in open(src) if l.strip()]
now = datetime.datetime.now().isoformat(timespec="seconds")
if dry == "1":
    print("[dream-scan] DRY_RUN: %d finding(s), nothing written" % len(fs)); sys.exit(0)
json.dump({"generated_at": now, "script": "dream-scan.sh", "count": len(fs), "findings": fs}, open(out, "w"), indent=2)
with open(hist, "a") as h:
    for f in fs: h.write(json.dumps({"at": now, "repo": f.get("repo", ""), "product": f["product"], "class": f["class"], "key": f["key"], "severity": f["severity"], "title": f["title"], "evidence": f["evidence"]}) + "\n")
print("[dream-scan] %d finding(s) -> %s" % (len(fs), out))
PY
exit 0
