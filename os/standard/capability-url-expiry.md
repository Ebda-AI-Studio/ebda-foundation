# Capability URL token with no expiry

Pack: security, privacy | Probe type: S+J | Source: Ebda AI Studio audit 2026-10-26 SEC-15

## Claim
A link that grants access by possession (guest order page) needs an expiry or a second factor.

## Scenario
Ebda's guest order page URL showed the buyer's order and address to anyone holding the link, forever.

## Source candidate
- (medium) Guest/public order token is checked without any expiry.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading. This lens is judge-graded: the probe only locates the candidate, the verdict needs the surrounding product behaviour.

## Fix template
Add expiresAt to the token and ask for the last digits of the phone before showing PII.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
