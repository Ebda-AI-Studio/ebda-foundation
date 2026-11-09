# No decision record (ADR / rulings)

Pack: business, cicd | Probe type: J | Source: Iceberg Audit term gap (no mechanical lens before 2026-10-26) 8

## Claim
Decisions that override a plan or accept a risk need a written record with the cost if wrong, or the next person re-litigates them.

## Scenario
Ebda keeps a register and a RULINGS file; a repo without one has no memory of why.

## Source candidate
- (low) No ADR/RULINGS/decisions document exists.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading. This lens is judge-graded: the probe only locates the candidate, the verdict needs the surrounding product behaviour.

## Fix template
Add docs/RULINGS.md or docs/adr/ and write each decision at decision time.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
