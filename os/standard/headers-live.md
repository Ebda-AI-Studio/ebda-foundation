# Security headers missing on a live host

Pack: security | Probe type: H | Source: Ebda AI Studio audit 2026-10-26 SEC-7, OPS-21

## Claim
Every public host (not only the main site) serves HSTS, a frame policy and a CSP.

## Scenario
accounts.ebda.app had no HSTS, frame or CSP headers and status.ebda.app had no HSTS, while the marketing site was fine. The check ran on one host only.

## Source candidate
- (medium) Live response has no Strict-Transport-Security header.
- (medium) Live response has neither X-Frame-Options nor a CSP frame-ancestors.
- (medium) Live response has no Content-Security-Policy header.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Set the header block in one shared helper used by every Worker; verify each host with the snapshot probe.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
