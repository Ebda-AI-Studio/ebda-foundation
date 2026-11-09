# Audit writes after the money moved, inside the same transaction

Pack: money | Probe type: S+J | Source: Ebda AI Studio audit 2026-10-26 BUG-14

## Claim
After an irreversible external call, only record the outcome; put audit/fan-out writes in an outbox so a failure there cannot roll back evidence of money that moved.

## Scenario
Ebda admin /payments/refund wrote audit rows inside the request transaction after the refund call; an audit failure rolled the transaction back while the money had already left.

## Source candidate
- (medium) Audit write follows an irreversible gateway call inside the same flow/transaction.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading. This lens is judge-graded: the probe only locates the candidate, the verdict needs the surrounding product behaviour.

## Fix template
Commit the outcome row first, then write audit via an outbox/queue.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
