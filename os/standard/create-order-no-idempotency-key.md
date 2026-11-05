# Order/payment create endpoint without a client idempotency key

Pack: money | Probe type: S | Source: Ebda master catalogue 2026-10-26 sec.7 L15

## Claim
Every create endpoint that moves money takes a client idempotency key and claims its input (cart row) inside the transaction.

## Scenario
Ebda place-order had no idempotency or cart claim: a double-submit or timeout retry created two orders (M-012).

## Source candidate
- (high) Order/payment create route with no idempotency handling in the file.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Require an Idempotency-Key header; claim the cart row FOR UPDATE inside the transaction.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
