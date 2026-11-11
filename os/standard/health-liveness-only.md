# /health proves liveness only

Pack: reliability, observability | Probe type: S | Source: Ebda AI Studio audit 2026-10-26 OPS-12

## Claim
A health endpoint must report the running commit and a dependency check, so 'is it deployed' is answerable from the running system.

## Scenario
Ebda /health proved liveness only; web, admin and orders could not report which commit they ran.

## Source candidate
- (medium) /health route exists but returns no commit and runs no dependency check.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Return { commit, deploymentId, db: ok } and compare commit to main's tip after every deploy.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
