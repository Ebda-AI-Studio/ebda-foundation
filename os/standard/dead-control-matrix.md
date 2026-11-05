# UI controls wired to nothing

Pack: observability, frontend | Probe type: S+J | Source: Ebda AI Studio audit 2026-10-26 CODE-5

## Claim
A button with an empty handler or href="#" is a dead control; a control matrix that counts it wired hides it.

## Scenario
Ebda Dahab product rows had dead controls and the control matrix reported them as wired.

## Source candidate
- (medium) Control with an empty/undefined handler or href="#".

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading. This lens is judge-graded: the probe only locates the candidate, the verdict needs the surrounding product behaviour.

## Fix template
Delete the control or wire it; add a negative-control test that fails on an empty handler.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
