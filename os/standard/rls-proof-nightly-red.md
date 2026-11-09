# RLS strict-policy proof is failing

Pack: tenancy, cicd | Probe type: H | Source: Ebda AI Studio audit 2026-10-26 OPS-10

## Claim
The scheduled proof that row-level security still isolates tenants must be green; red for days means isolation is unproven.

## Scenario
Ebda's nightly RLS strict-policy proof was red for two nights.

## Source candidate
- (high) Latest RLS proof run concluded failure.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Fix the proof first; gate PRs on the affected tier.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
