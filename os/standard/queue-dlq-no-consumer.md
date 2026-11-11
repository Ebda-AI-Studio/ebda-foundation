# Dead-letter queue configured with no consumer or alert

Pack: observability, cloudflare | Probe type: S | Source: Ebda master catalogue 2026-10-26 sec.7 L79

## Claim
Every queue DLQ has a consumer and an alert.

## Scenario
Ebda queues declared dead-letter queues that nothing read and nothing alerted on (M-018).

## Source candidate
- (medium) dead_letter_queue is configured with no DLQ consumer reference.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Add a DLQ consumer that stores and alerts.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
