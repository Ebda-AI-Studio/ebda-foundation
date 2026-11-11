# Outbound WhatsApp with no recorded opt-in

Pack: meta-whatsapp, privacy | Probe type: S+J | Source: Meta WhatsApp Business policy (opt-in) + PDPL consent

## Claim
Business-initiated WhatsApp messages need a recorded, specific opt-in per contact.

## Scenario
Without an opt-in record a merchant cannot show consent after a complaint or a Meta review.

## Source candidate
- (high) WhatsApp send code exists but no opt-in/consent record is referenced.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading. This lens is judge-graded: the probe only locates the candidate, the verdict needs the surrounding product behaviour.

## Fix template
Store opt-in source, timestamp and wording per contact; block sends without it.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
