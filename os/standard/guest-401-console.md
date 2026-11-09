# Guest page load logs 401 errors

Pack: frontend, reliability | Probe type: H | Source: Ebda AI Studio audit 2026-10-26 UI-8

## Claim
A page loaded by a signed-out visitor must not call authenticated endpoints and log 401s.

## Scenario
Every Ebda guest page load logged 401 errors from auth/me and auth/refresh.

## Source candidate
- (low) Console snapshot shows 401 responses on a guest load.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Skip session calls when no session cookie exists.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
