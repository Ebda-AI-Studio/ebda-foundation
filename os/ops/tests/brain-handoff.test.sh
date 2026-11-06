#!/usr/bin/env bash
# Act-not-ping: dream / reflect / self-heal / app-error-heal findings go to the brain's POST /findings (Bearer INGEST_TOKEN), or to
# a local spool when the brain is not configured or unreachable. Nothing may call notify.sh. Fake HOME, fake brain on a loopback port.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1; OPS="$(pwd)"
T="$(mktemp -d)"; SRV=""
trap '[ -n "$SRV" ] && kill "$SRV" 2>/dev/null; rm -rf "$T"' EXIT
_pass=0; _fail=0
pass() { echo "PASS: $1"; _pass=$((_pass+1)); }
fail() { echo "FAIL: $1"; _fail=$((_fail+1)); }
mkdir -p "$T/home" "$T/state" "$T/proj/Ebda-AI-Studio/internal-projects/ebda-store/.git" "$T/phases"
: > "$T/services.env"
E=(env HOME="$T/home" EBDA_OS_LOCAL_ENV="$T/none.env" EBDA_OS_LOCAL_JSON="$T/local.json" OS_STATE_DIR="$T/state" OS_SERVICES_ENV="$T/services.env" OS_PROJECTS_DIR="$T/proj" OS_HOME="$T/fnd")
SPOOL="$T/state/brain-spool.ndjson"

# a fake brain: records method, path, auth header and body of each request; 401 without the right bearer
cat > "$T/brain.py" <<'PY'
import http.server, json, sys
LOG = sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        n = int(self.headers.get("content-length") or 0); body = self.rfile.read(n).decode()
        ok = self.headers.get("authorization") == "Bearer tok123"
        open(LOG, "a").write(json.dumps({"path": self.path, "auth": ok, "body": json.loads(body)}) + "\n")
        self.send_response(200 if ok else 401); self.end_headers(); self.wfile.write(b"{}")
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
PORT=$((20000 + RANDOM % 20000))
python3 -I "$T/brain.py" "$PORT" "$T/brain.log" & SRV=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do curl -s -o /dev/null -m 1 -X POST "http://127.0.0.1:$PORT/x" -d '{}' && break; sleep 0.3; done
: > "$T/brain.log"

cat > "$T/df.json" <<'J'
{"findings":[{"repo":"__memory__","class":"reflect-unenforced-lesson","severity":"high","file":"feedback-x.md","title":"recurring unenforced lesson: x-y","detail":"d","fix":"add a gate","autofixable":false},
             {"repo":"Ebda-AI-Studio/ebda-store","class":"lockfile-drift","severity":"low","file":"package-lock.json","title":"lock drift","autofixable":true}]}
J
lib() { "${E[@]}" bash -c ". '$OPS/lib/os-config.sh'; os_config_load; . '$OPS/lib/brain-post.sh'; $1"; }

# 1. mapping: dream findings -> brain Finding shape (validateFinding's required fields, severity map, repo only when owner/name)
m="$(lib "brain_dream_to_findings '$T/df.json'")"
python3 -I -c "
import json,sys; a=json.loads(sys.argv[1])
ok = len(a)==2 and all(x['source']=='dream' and x['key'] and x['title'] for x in a) and a[0]['severity']=='P2' and 'repo' not in a[0] and a[1]['repo']=='Ebda-AI-Studio/ebda-store' and a[1]['severity']=='P3'
sys.exit(0 if ok else 1)" "$m" && pass "dream findings map to brain findings" || { fail "mapping wrong"; echo "$m"; }

# 2. unconfigured brain: spooled, returns 10, no network
lib "brain_dream_to_findings '$T/df.json' > '$T/arr.json'; brain_post_findings '$T/arr.json'" 2>/dev/null; rc=$?
[ "$rc" = 10 ] && pass "unconfigured brain returns 10 (spooled)" || fail "rc=$rc, want 10"
[ "$(wc -l < "$SPOOL" 2>/dev/null | tr -d ' ')" = 2 ] && pass "two findings spooled, one per line" || fail "spool wrong"

# 3. configured brain: first the spool drains, then the new batch posts; Bearer sent
printf 'OS_BRAIN_URL=http://127.0.0.1:%s\nINGEST_TOKEN=tok123\n' "$PORT" > "$T/services.env"
lib "brain_post_findings '$T/arr.json'"; rc=$?
[ "$rc" = 0 ] && pass "configured brain returns 0" || fail "rc=$rc"
n="$(python3 -I -c "
import json,sys
rows=[json.loads(l) for l in open(sys.argv[1])]
print(len(rows), all(r['path']=='/findings' and r['auth'] for r in rows), sum(len(r['body']) for r in rows))" "$T/brain.log")"
[ "$n" = "2 True 4" ] && pass "spool drained + new batch posted to /findings with the bearer (2 requests, 4 findings)" || fail "brain saw: $n"
[ ! -s "$SPOOL" ] && pass "spool emptied after delivery" || fail "spool not emptied"

# 4. wrong token: 401 -> spooled again, not lost
printf 'OS_BRAIN_URL=http://127.0.0.1:%s\nINGEST_TOKEN=wrong\n' "$PORT" > "$T/services.env"
lib "brain_post_findings '$T/arr.json'" 2>/dev/null; rc=$?
{ [ "$rc" = 10 ] && [ "$(wc -l < "$SPOOL" | tr -d ' ')" = 2 ]; } && pass "a rejected POST is spooled, not dropped" || fail "401 handling rc=$rc"
: > "$SPOOL"; : > "$T/brain.log"

# 5. dream.sh end to end: absent phases are reported absent, reflect findings are handed to the brain, no notify
cat > "$T/phases/dream-reflect.sh" <<S
#!/usr/bin/env bash
cp '$T/df.json' "\$OS_STATE_DIR/dream-findings.json"
S
cat > "$T/phases/dream-scan.sh" <<'S'
#!/usr/bin/env bash
echo '{"findings":[]}' > "$OS_STATE_DIR/dream-findings.json"
S
cat > "$T/phases/notify.sh" <<S
#!/usr/bin/env bash
echo called >> '$T/notify.called'
S
printf 'OS_BRAIN_URL=http://127.0.0.1:%s\nINGEST_TOKEN=tok123\n' "$PORT" > "$T/services.env"
out="$("${E[@]}" DREAM_PHASES_DIR="$T/phases" bash "$OPS/dream.sh" --weekly --notify 2>&1)"; rc=$?
[ "$rc" = 0 ] && pass "dream.sh exits 0 with absent phases" || { fail "dream rc=$rc"; echo "$out"; }
echo "$out" | grep -q "dream-research.sh not installed - absent" && pass "an absent phase is reported absent" || fail "absent phase not reported"
[ "$(python3 -I -c "import json,sys; print(sum(len(json.loads(l)['body']) for l in open(sys.argv[1])))" "$T/brain.log")" = 2 ] && pass "dream findings reached the brain" || fail "no findings at the brain"
[ ! -e "$T/notify.called" ] && pass "no notify.sh call" || fail "notify was called"
python3 -I -c "
import json,sys; e=json.load(open(sys.argv[1]))['entries'][-1]
sys.exit(0 if e['run_mode']=='weekly' and e['total_findings']==2 and e['phases_status']['reflect']=='ok' and e['phases_status']['research']=='absent' else 1)" "$T/state/dream-ledger.json" && pass "learn-back ledger entry written" || fail "ledger entry wrong"
grep -rqE 'notify\.sh|NOTIFY' "$OPS/dream.sh" "$OPS/self-heal.sh" "$OPS/heal-watch.sh" "$OPS/app-error-heal.sh" "$OPS/dream-standard-drift.sh" "$OPS/dream-reflect.sh" 2>/dev/null \
  && fail "a ported script still references notify" || pass "no ported script references notify"

# 5b. a MISSING scan is a failure of the cycle: exit 1, ledger says so, a dream-scan-failed finding is handed over
mv "$T/phases/dream-scan.sh" "$T/phases/dream-scan.sh.off"; : > "$T/brain.log"; rm -f "$T/state/dream-ledger.json" "$T/state/dream-findings.json"
out="$("${E[@]}" DREAM_PHASES_DIR="$T/phases" bash "$OPS/dream.sh" --daily 2>&1)"; rc=$?
[ "$rc" = 1 ] && pass "missing scan -> dream.sh exits 1" || { fail "missing scan rc=$rc (want 1)"; echo "$out"; }
python3 -I -c "
import json,sys; e=json.load(open(sys.argv[1]))['entries'][-1]
sys.exit(0 if e['phases_status']['scan']=='failed:absent' else 1)" "$T/state/dream-ledger.json" && pass "ledger records scan failed:absent (not 'absent ok')" || fail "ledger scan status wrong"
python3 -I -c "
import json,sys
rows=[json.loads(l) for l in open(sys.argv[1])]
ks=[b['kind'] for r in rows for b in r['body']]
sys.exit(0 if 'dream-scan-failed' in ks else 1)" "$T/brain.log" && pass "a dream-scan-failed finding reached the brain" || fail "no dream-scan-failed finding"
# a scan that exits 0 but wrote no findings file is also a failure
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/phases/dream-scan.sh"
"${E[@]}" DREAM_PHASES_DIR="$T/phases" bash "$OPS/dream.sh" --daily >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && pass "scan that wrote no findings file -> exit 1" || fail "silent scan rc=$rc"
printf '#!/usr/bin/env bash\nexit 7\n' > "$T/phases/dream-scan.sh"
"${E[@]}" DREAM_PHASES_DIR="$T/phases" bash "$OPS/dream.sh" --daily >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && pass "scan that exits non-zero -> exit 1" || fail "failing scan rc=$rc"
rm -f "$T/phases/dream-scan.sh"; mv "$T/phases/dream-scan.sh.off" "$T/phases/dream-scan.sh"

# 6. reflect-only: runs just reflect + hand-off
: > "$T/brain.log"; rm -f "$T/state/dream-ledger.json"
"${E[@]}" DREAM_PHASES_DIR="$T/phases" bash "$OPS/dream.sh" --reflect-only >/dev/null 2>&1
python3 -I -c "
import json,sys; e=json.load(open(sys.argv[1]))['entries'][-1]
sys.exit(0 if e['phases_status']['reflect']=='ok' and e['phases_status']['research'].startswith('skipped') else 1)" "$T/state/dream-ledger.json" && pass "--reflect-only skips the other phases" || fail "reflect-only wrong"

# 7. no brain url + no token: dream still succeeds and spools
: > "$T/services.env"; : > "$SPOOL"
"${E[@]}" DREAM_PHASES_DIR="$T/phases" bash "$OPS/dream.sh" --weekly >/dev/null 2>&1
[ "$(wc -l < "$SPOOL" | tr -d ' ')" = 2 ] && pass "dream spools when the brain is not configured" || fail "dream did not spool"

# 8. self-heal registry from the local config + heal_report -> spooled P1 selfHealExhausted finding; Ebda-only (empty list = no registry)
rm -f "$T/local.json"
"${E[@]}" bash -c ". '$OPS/lib/os-config.sh'; os_config_load; . '$OPS/lib/heal-registry.sh'; heal_registry_path" >/dev/null 2>&1 && fail "registry built from nothing" || pass "no heal_services -> no registry"
printf '{"heal_services":["ebda-api|Ebda API|railway|https://api.example.test/health|200|railway-redeploy|railway_project=p1,railway_service=api,railway_env=prod"]}' > "$T/local.json"
reg="$("${E[@]}" bash -c ". '$OPS/lib/os-config.sh'; os_config_load; . '$OPS/lib/heal-registry.sh'; heal_registry_path" 2>/dev/null)"
python3 -I -c "
import json,sys; s=json.load(open(sys.argv[1]))['services'][0]
sys.exit(0 if s['id']=='ebda-api' and s['recovery']=='railway-redeploy' and s['railway_service']=='api' and s['enabled'] else 1)" "$reg" && pass "registry built from heal_services" || fail "registry wrong: $reg"
: > "$SPOOL"
"${E[@]}" bash -c ". '$OPS/lib/os-config.sh'; os_config_load; . '$OPS/lib/brain-post.sh'; . '$OPS/lib/heal-registry.sh'; heal_report prod-outage P1 true ebda-api 'Ebda API down'" 2>/dev/null
python3 -I -c "
import json,sys; o=json.loads(open(sys.argv[1]).readline())
sys.exit(0 if o['source']=='self-heal' and o['kind']=='prod-outage' and o['severity']=='P1' and o['selfHealExhausted'] is True and o['key'].startswith('ebda-api@') else 1)" "$SPOOL" && pass "an exhausted heal becomes a P1 prod-outage finding" || fail "heal_report wrong"

# 9. heal-watch with no services configured: exits 0, no probes, no spool growth
rm -f "$T/local.json"; : > "$SPOOL"
"${E[@]}" bash "$OPS/heal-watch.sh" >"$T/hw.out" 2>&1; rc=$?
{ [ "$rc" = 0 ] && grep -q "NO SERVICES REGISTERED" "$T/hw.out"; } && pass "heal-watch with no services: exit 0 but LOUD" || { fail "heal-watch rc=$rc"; cat "$T/hw.out"; }
grep -q "NO SERVICES REGISTERED" "$T/state/heal.log" && pass "the empty registry is in heal.log" || fail "not logged"
python3 -I -c "
import json,sys; o=json.loads(open(sys.argv[1]).readline())
sys.exit(0 if o['kind']=='monitor-unconfigured' else 1)" "$SPOOL" && pass "one monitor-unconfigured finding handed over" || fail "no finding"
"${E[@]}" bash "$OPS/heal-watch.sh" >/dev/null 2>&1
[ "$(wc -l < "$SPOOL" | tr -d ' ')" = 1 ] && pass "reported once, not every cycle" || fail "re-reported"

echo "── $_pass passed, $_fail failed ──"
[ "$_fail" -eq 0 ]
