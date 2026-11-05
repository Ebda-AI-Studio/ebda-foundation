# No load test for the current architecture

Pack: perf, reliability | Probe type: S | Source: Ebda master catalogue 2026-10-26 sec.7 L49

## Claim
A load baseline must exist for the current architecture and one hot tenant before each platform change.

## Scenario
Ebda had no load baseline for the Workers + Hyperdrive stack or a hot tenant (M-056, M-041).

## Source candidate
- (medium) No k6/artillery/load-test file in the repository.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Add a k6 script for the top five routes and one hot tenant; run it before each platform change.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
