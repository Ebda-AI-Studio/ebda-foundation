# Cross-product contract package on a floating version

Pack: cicd | Probe type: S | Source: Ebda master catalogue 2026-10-26 sec.7 L81

## Claim
Cross-product contracts pin version and sha, make compat fields required over time, and probe secret equality across Workers.

## Scenario
Ebda Store and WhatsApp shared contracts through floating ranges, so one repo could break the other silently (M-058, M-172, M-061).

## Source candidate
- (low) Contract package declared with ^, ~, * or latest.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Pin the contract package exactly and test both sides against the pinned version.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
