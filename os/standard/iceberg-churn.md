# No cancellation reason, dunning or win-back path

Pack: business | Probe type: J | Source: Iceberg Audit term gap (no mechanical lens before 2026-10-26) 14

## Claim
A subscription product needs a cancel flow that records why, retries failed cards (dunning) and tries to win the customer back.

## Scenario
Ebda's 14-day Growth trial may be too short and card-bound for a COD boutique, and churn cannot be understood without cancellation reasons.

## Source candidate
- (medium) Subscription code exists but no cancellation-reason, dunning or win-back is referenced.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading. This lens is judge-graded: the probe only locates the candidate, the verdict needs the surrounding product behaviour.

## Fix template
Add cancel-reason capture, a dunning schedule and one win-back message.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
