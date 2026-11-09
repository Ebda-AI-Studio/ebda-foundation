# Deploy workflow failing on main

Pack: cicd | Probe type: H | Source: Ebda AI Studio audit 2026-10-26 OPS-2, OPS-3, OPS-4

## Claim
The latest runs of the deploy workflows on main must be green; a red deploy means production is behind main and its verify/rollback steps never ran.

## Scenario
Ebda storefront auto-deploy failed on main so prod web lagged; the API deploy was red four pushes in a row; accounts failed every push because the CI Cloudflare token could not touch D1.

## Source candidate
- (high) A recent deploy run on main concluded failure/cancelled.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Fix the failing step, then make the deploy a required check and add a notify-failure job.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
