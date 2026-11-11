# Failed/expired transition with no guard on the current status

Pack: money | Probe type: S | Source: Ebda AI Studio audit 2026-10-26 BUG-6

## Claim
Every transition into failed/expired must carry the allowed source states in its WHERE, or a late failure can overwrite a paid order.

## Scenario
Ebda's pull-side verifier marked an order failed after a webhook had already marked it paid; the money stayed, the order said failed.

## Source candidate
- (high) Order/payment set to failed/expired with no status condition in the update's where.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
UPDATE ... WHERE id = ? AND status = 'pending'; treat zero rows as already settled.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
