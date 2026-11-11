# No required status checks on the default branch

Pack: cicd | Probe type: H | Source: Ebda AI Studio audit 2026-10-26 OPS-11

## Claim
The default branch must require status checks server-side; a local pre-push hook is a preference, not a gate.

## Scenario
Ebda could not enforce required checks server-side and production deploys had no gate.

## Source candidate
- (high) Branch protection snapshot has no required_status_checks.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Add a ruleset/branch protection requiring the CI checks and the merge-gate job.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
