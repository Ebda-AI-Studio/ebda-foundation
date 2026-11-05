# No dated launch-day checklist with owners

Pack: business | Probe type: J | Source: Ebda master catalogue 2026-10-26 sec.7 L72

## Claim
Launch-day assets (refund page, deletion page, SLA, invoice series, pricing URL) are a dated checklist with owners.

## Scenario
Ebda's launch-day assets did not exist and nobody owned them (M-088).

## Source candidate
- (medium) No launch checklist document exists.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading. This lens is judge-graded: the probe only locates the candidate, the verdict needs the surrounding product behaviour.

## Fix template
Create docs/LAUNCH-CHECKLIST.md with owner and date per asset.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
