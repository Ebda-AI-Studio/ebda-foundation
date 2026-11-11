# Published OpenAPI covers a small fraction of the routes

Pack: docs | Probe type: S | Source: Ebda AI Studio audit 2026-10-26 DOC-9

## Claim
The OpenAPI document should describe the routes the API serves, or say which subset it covers.

## Scenario
Ebda's published OpenAPI described 4 paths of roughly 760 route handlers.

## Source candidate
- (low) OpenAPI paths are under a tenth of the route handlers.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Generate the spec from the route/Zod definitions in CI.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
