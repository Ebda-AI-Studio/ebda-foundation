# Tenant-level kill switch held in an environment variable

Pack: reliability | Probe type: S | Source: Ebda master catalogue 2026-10-26 sec.7 L75

## Claim
Operator kill switches exist for every tenant-level capability and are data (D1), not deploy-time variables.

## Scenario
Ebda could only disable a misbehaving merchant's feature by redeploying with a changed variable (M-100).

## Source candidate
- (low) Kill/disable switch read from process.env.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Store the switch per tenant in the database and read it on every send.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
