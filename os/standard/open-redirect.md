# Redirect target taken from the request without validation

Pack: security | Probe type: S | Source: Builder-reality reel pack (reel-lenses-2026-09) + playbook sec 14, L5

## Claim
A post-login or callback redirect built from a query parameter must be restricted to same-origin paths or an allowlist.

## Scenario
A login link with ?next=https://evil.example delivers the user (and sometimes the token) to the attacker's server.

## Source candidate
- (medium) redirect() target comes from a request parameter with no visible same-origin/allowlist check.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Accept only paths starting with a single slash, or compare the parsed origin against an allowlist.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
