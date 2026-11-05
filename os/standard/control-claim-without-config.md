# Docs claim a control (PITR window, 3-2-1 backup) with no config key behind it

Pack: docs, data | Probe type: J | Source: Ebda master catalogue 2026-10-26 sec.7 L06

## Claim
A documented control must cite the config key that implements it; docs may only describe controls that exist.

## Scenario
Docs promised a 7-day Neon PITR window while the project had 6 hours; the 3-2-1 backup claim had no off-machine copy (M-005, M-011).

## Source candidate
- (medium) A retention/PITR/backup number is stated with no config reference.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading. This lens is judge-graded: the probe only locates the candidate, the verdict needs the surrounding product behaviour.

## Fix template
Cite the setting (and read it back in CI) next to every control claim.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
