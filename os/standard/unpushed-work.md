# Local branches with commits that exist on no remote

Pack: cicd | Probe type: H | Source: Ebda master catalogue 2026-10-26 sec.7 L13

## Claim
Work that exists only on one machine or an unpushed branch is a single point of loss; push it and put it in the merge order.

## Scenario
Ebda's search-on-DO work lived only in a local, unpushed branch (M-046).

## Source candidate
- (medium) Snapshot shows local branches ahead of or missing a remote.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Push the branch (or delete it) and list it in the merge train.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
