# Code marked dormant or retired but still shipping

Pack: cicd | Probe type: S | Source: Ebda master catalogue 2026-10-26 sec.7 L46

## Claim
After a ruling retires a flow, sweep the dormant code, nav entries and tables it leaves behind.

## Scenario
Ebda kept dormant and dead code that still shipped after rulings retired the flows (M-152).

## Source candidate
- (low) Comment says the code is dormant/retired/legacy flow.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Delete it in the PR that records the ruling.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
