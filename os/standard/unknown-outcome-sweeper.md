# Pending charge with no reconciliation job

Pack: money, reliability | Probe type: S+J | Source: Ebda AI Studio audit 2026-10-26 BUG-3

## Claim
A charge whose outcome is unknown must be polled against the gateway and alerted on by age; otherwise it stays pending forever.

## Scenario
A renewal charge with an unknown outcome stayed `pending` for good: nothing polled the gateway and nothing alerted.

## Source candidate
- (high) Charges are written as pending but no reconcile/sweep job for stale pending rows exists.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading. This lens is judge-graded: the probe only locates the candidate, the verdict needs the surrounding product behaviour.

## Fix template
Add a scheduled reconcile that queries the gateway for rows pending longer than N minutes, resolves them, and alerts on any older than a day.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
