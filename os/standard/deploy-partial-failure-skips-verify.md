# A failing deploy step can skip the verify and rollback steps

Pack: cicd | Probe type: S | Source: Ebda master catalogue 2026-10-26 sec.7 L02

## Claim
Verify and rollback steps of a deploy job must run even when an earlier step fails partially (cron-trigger PUT).

## Scenario
Ebda's API deploy failed on a cron-trigger PUT, so its verify, rollback and Inngest-sync steps never ran (M-007).

## Source candidate
- (high) Workflow with deploy and verify/rollback steps has no always()/failure() condition.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Give verify/rollback `if: always()` or split them into a job that needs the deploy and runs on failure().

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
