# Script CSP allows unsafe-inline or unsafe-eval

Pack: security, frontend | Probe type: S | Source: Ebda AI Studio audit 2026-10-26 SEC-4

## Claim
script-src with 'unsafe-inline' or 'unsafe-eval' turns the CSP into decoration against XSS.

## Scenario
Ebda admin, orders and storefront shipped script-src with unsafe-inline and unsafe-eval while the admin kept its bearer token in localStorage.

## Source candidate
- (high) script-src allows 'unsafe-inline' or 'unsafe-eval'.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Use nonces or hashes for scripts, remove eval, and keep tokens out of script-readable storage.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
