# Access token stored in localStorage

Pack: security, frontend | Probe type: S | Source: Ebda AI Studio audit 2026-10-26 SEC-4

## Claim
A bearer/session token in localStorage is readable by any script that runs on the page.

## Scenario
Ebda admin and orders kept the bearer token in localStorage next to a CSP that allowed inline scripts, so one XSS meant account takeover.

## Source candidate
- (high) Token/credential written to localStorage, readable by any script on the page.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Move the session to an httpOnly, Secure, SameSite cookie.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
