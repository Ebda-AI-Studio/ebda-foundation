# Webhook body persisted or queued before its signature is verified

Pack: security, money | Probe type: S | Source: Ebda AI Studio audit 2026-10-26 SEC-5

## Claim
A webhook handler must verify the signature on the raw body before it writes the body to a table or a queue.

## Scenario
Ebda payment webhooks were written to the webhook table and queued, and only then verified. Anyone who could reach the URL could fill the table and the queue with unsigned bodies.

## Source candidate
- (high) Webhook handler persists or enqueues the payload before verifying its signature.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Verify the HMAC over the raw body first and return 401; persist and enqueue only after it passes.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
