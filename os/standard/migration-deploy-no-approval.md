# Workflow runs migrations with no approval environment

Pack: cicd, data | Probe type: S | Source: Ebda master catalogue 2026-10-26 sec.7 L59

## Claim
When the platform cannot enforce branch protection, put a manual approval step in front of migrations and rule the residual.

## Scenario
Ebda could not enforce required checks, so a push to main could migrate production unreviewed (M-102).

## Source candidate
- (high) Workflow applies migrations with no environment/approval.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Run migrations in a job with `environment: production` and required reviewers.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
