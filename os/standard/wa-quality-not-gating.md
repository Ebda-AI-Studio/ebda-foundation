# Sender quality / account events do not gate sending

Pack: meta-whatsapp | Probe type: S | Source: Ebda master catalogue 2026-10-26 sec.7 L73

## Claim
Third-party number health (Meta quality rating, account events) is an input to the send gate, not a dashboard field.

## Scenario
Ebda showed number quality in a dashboard but kept sending through a degrading number (M-043).

## Source candidate
- (high) WhatsApp send code exists with no quality-rating/messaging-limit handling.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Read quality_rating/messaging_limit from the webhook and throttle or stop sends.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
