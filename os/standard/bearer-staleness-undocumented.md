# Stateless bearer verified with no stated staleness window

Pack: security | Probe type: J | Source: Ebda master catalogue 2026-10-26 sec.7 L32

## Claim
The bounded-stale window of a stateless bearer (how long a revoked token still works) must be documented at the check site.

## Scenario
Ebda inbox/API tokens were only revocation-checked for money actions (M-135).

## Source candidate
- (low) JWT/bearer verification with no staleness or revocation note.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading. This lens is judge-graded: the probe only locates the candidate, the verdict needs the surrounding product behaviour.

## Fix template
Add a comment/constant stating the window and the revocation path.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
