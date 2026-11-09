#!/usr/bin/env bash
# Test osv-severity.py — advisory severity extraction for dream-research.sh.
# Run: bash ops/lib/__tests__/osv-severity.test.sh
set -euo pipefail

LIB="$(cd "$(dirname "$0")/.." && pwd)"
_pass=0
_fail=0

assert_py() {
  local label="$1" pycode="$2"
  if LIB="$LIB" python3 - <<PY
import importlib.util, os
spec = importlib.util.spec_from_file_location("osv", os.path.join(os.environ["LIB"], "osv-severity.py"))
osv = importlib.util.module_from_spec(spec); spec.loader.exec_module(osv)
${pycode}
PY
  then echo "PASS: $label"; _pass=$((_pass + 1))
  else echo "FAIL: $label"; _fail=$((_fail + 1)); fi
}

# --- the real advisory the OS reported as "unknown" on 2026-08-18 -------------
# GHSA-ggr8-5vv4-36mx: deepmerge-ts stack exhaustion, GitHub-reviewed HIGH,
# hitting ebda-studio, digital-card, ebda-store and mypovonai.
# The OS summarised the batch containing it as "critical=0 high=0".
assert_py "GitHub-reviewed severity wins (the real 2026-08-18 advisory)" "
vuln = {
  'id': 'GHSA-ggr8-5vv4-36mx',
  'summary': 'DeepmergeTS has stack exhaustion when merging recursive object graphs',
  'aliases': ['CVE-2026-40345'],
  'severity': [{'type':'CVSS_V4','score':'CVSS:4.0/AV:N/AC:L/AT:P/PR:N/UI:N/VC:N/VI:N/VA:H/SC:N/SI:N/SA:N'}],
  'database_specific': {'severity':'HIGH','cwe_ids':['CWE-674']},
}
assert osv.severity_of(vuln) == 'high', osv.severity_of(vuln)
assert osv.cve_ids_of(vuln) == ['CVE-2026-40345'], osv.cve_ids_of(vuln)
assert 'stack exhaustion' in osv.summary_of(vuln)
"

assert_py "GitHub 'MODERATE' normalises to medium" "
assert osv.severity_of({'database_specific':{'severity':'MODERATE'}}) == 'medium'
"

# --- a querybatch stub must be UNKNOWN, never silently low/zero --------------
# /v1/querybatch returns ONLY {id, modified}. Reading severity off that stub is
# exactly how 39/39 advisories came back 'unknown' while the digest reported
# critical=0 high=0 and read like an all-clear.
assert_py "querybatch stub yields unknown, not a made-up bucket" "
assert osv.severity_of({'id':'GHSA-x','modified':'2026-08-17T13:45:07Z'}) == 'unknown'
assert osv.needs_hydration({'id':'GHSA-x','modified':'2026-08-17T13:45:07Z'}) is True
assert osv.needs_hydration({'id':'GHSA-x','database_specific':{'severity':'HIGH'}}) is False
"

# --- CVSS fallback when GitHub has not reviewed ------------------------------
assert_py "numeric CVSS score buckets correctly" "
def sev(score, t='CVSS_V3'):
    return osv.severity_of({'severity':[{'type':t,'score':score}]})
assert sev('9.8') == 'critical', sev('9.8')
assert sev('7.5') == 'high', sev('7.5')
assert sev('5.3') == 'medium', sev('5.3')
assert sev('2.1') == 'low', sev('2.1')
"

assert_py "a CVSS VECTOR string is scored, not silently bucketed as medium" "
# The old code did: float(...) if 'CVSS' not in score else 5.0 — the ternary is
# inverted, so every real vector (which always contains 'CVSS') became 5.0 =>
# 'medium'. A CVSS:3.1 AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H vector is 9.8 CRITICAL.
v = 'CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H'
assert osv.severity_of({'severity':[{'type':'CVSS_V3','score':v}]}) == 'critical', osv.severity_of({'severity':[{'type':'CVSS_V3','score':v}]})
v_low = 'CVSS:3.1/AV:L/AC:H/PR:H/UI:R/S:U/C:L/I:N/A:N'
assert osv.severity_of({'severity':[{'type':'CVSS_V3','score':v_low}]}) in ('low','medium'), osv.severity_of({'severity':[{'type':'CVSS_V3','score':v_low}]})
"

assert_py "unparseable severity data stays unknown rather than guessing" "
assert osv.severity_of({'severity':[{'type':'CVSS_V3','score':'nonsense'}]}) == 'unknown'
assert osv.severity_of({}) == 'unknown'
assert osv.severity_of(None) == 'unknown'
"

# --- counting must expose unknown, never fold it into zero -------------------
assert_py "tally reports unknown as its own bucket" "
advs = [{'severity':'high'},{'severity':'unknown'},{'severity':'unknown'},{'severity':'critical'}]
t = osv.tally(advs)
assert t['critical'] == 1, t
assert t['high'] == 1, t
assert t['unknown'] == 2, t
"

assert_py "a fully-unknown batch is NOT reportable as an all-clear" "
advs = [{'severity':'unknown'} for _ in range(39)]
t = osv.tally(advs)
assert t['unknown'] == 39, t
assert osv.is_all_clear(t) is False, 'a batch of 39 unknowns must never read as all-clear'
assert osv.is_all_clear(osv.tally([{'severity':'low'}])) is True
assert osv.is_all_clear(osv.tally([])) is True
"

echo
echo "osv-severity: PASS=$_pass FAIL=$_fail"
[ "$_fail" -eq 0 ]
