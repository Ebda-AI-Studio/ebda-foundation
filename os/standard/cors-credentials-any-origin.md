# CORS reflects any origin while allowing credentials

Pack: security | Probe type: S | Source: Builder-reality reel pack (reel-lenses-2026-09) + playbook sec 14, L10

## Claim
Access-Control-Allow-Origin must be an allowlist when cookies or credentials are allowed.

## Scenario
The browser attaches the visitor's cookies to a request from any site; a reflected Origin plus credentials lets that site read the response.

## Source candidate
- (high) CORS reflects the request Origin (or allows any origin) with credentials enabled and no allowlist.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Compare the Origin against an allowlist and echo only a listed value.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
