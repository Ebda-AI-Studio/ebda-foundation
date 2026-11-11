# Verified webhook for an unseen row is acknowledged and dropped

Pack: money, data | Probe type: S | Source: Ebda AI Studio audit 2026-10-26 BUG-8, DB-2

## Claim
When the row a webhook refers to is not visible yet (replica lag, eventual consistency), answer non-2xx so the sender retries, or park the event.

## Scenario
Ebda's webhook route answered 200 'ignored' on an entity-index miss; the payment confirmation was dropped and never retried.

## Source candidate
- (high) Webhook handler answers 2xx 'ignored' for an unmatched record with no retry/park path.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Return 503 (retry) or write the event to a dead-letter table and reprocess.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
