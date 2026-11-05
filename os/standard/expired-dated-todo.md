# A dated TODO whose date has passed

Pack: cicd | Probe type: S | Source: Ebda master catalogue 2026-10-26 sec.7 L47

## Claim
Dated TODOs expire in CI; an overdue one is a decision nobody made.

## Scenario
Ebda's signup anti-abuse token TODO was long overdue (M-155).

## Source candidate
- (low) TODO carries a date that is in the past.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Do it or delete it; make CI fail on an expired date.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
