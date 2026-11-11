# Integration/RLS/E2E tier runs only on a schedule

Pack: cicd | Probe type: S | Source: Ebda AI Studio audit 2026-10-26 CODE-1, CODE-2

## Claim
A workflow that runs the integration, RLS or end-to-end tier must be triggered by pull_request or push, not only by cron.

## Scenario
Ebda's money-path integration, RLS and E2E tiers never ran on a PR or after a merge; they ran nightly, so a regression was found a day later or never.

## Source candidate
- (high) Workflow runs integration/RLS/e2e tests with a schedule trigger but no pull_request/push trigger.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Run the affected tier on pull_request (path filtered); keep the heavy full tier nightly in addition.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
