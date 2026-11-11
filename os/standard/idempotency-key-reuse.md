# Idempotency key that cannot change after a failed attempt

Pack: money | Probe type: S+J | Source: Ebda AI Studio audit 2026-10-26 BUG-4

## Claim
A key derived only from the order id makes a failed or rejected refund impossible to retry; the gateway replays the old failure.

## Scenario
After one failed refund, Ebda billing retries reused the same key and the gateway returned the cached failure forever.

## Source candidate
- (medium) Idempotency key built from the order/charge id alone (no attempt or nonce part).

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading. This lens is judge-graded: the probe only locates the candidate, the verdict needs the surrounding product behaviour.

## Fix template
Key by order plus attempt number; only reuse the key for in-flight or successful attempts.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
