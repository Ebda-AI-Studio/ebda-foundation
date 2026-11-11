# CI Cloudflare token used for D1 with no D1 permission noted

Pack: cloudflare, cicd | Probe type: S+J | Source: Ebda AI Studio audit 2026-10-26 OPS-4

## Claim
The CI API token must carry every permission the deploy needs (D1 edit, Workers scripts, KV, R2).

## Scenario
Ebda's accounts auto-deploy failed on every push because the CI Cloudflare token could not touch D1.

## Source candidate
- (high) Workflow deploys with CLOUDFLARE_API_TOKEN and D1 but never documents a D1 permission.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading. This lens is judge-graded: the probe only locates the candidate, the verdict needs the surrounding product behaviour.

## Fix template
Scope the token to the resources the workflow binds and document it next to the workflow.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
