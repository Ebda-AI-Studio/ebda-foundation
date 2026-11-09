# Model reply sent to a customer with no URL/price/promise guard

Pack: ai-safety, meta-whatsapp | Probe type: S+J | Source: Ebda AI Studio audit 2026-10-26 SEC-10

## Claim
Anything a model writes to a buyer must pass a deterministic post-filter: no links outside an allowlist, no prices or discounts the store did not set, no promises (refund, delivery date).

## Scenario
Ebda WhatsApp agent replies had no URL, price or promise guard, so a hostile buyer could make the shop's own number send a phishing link or an invented discount.

## Source candidate
- (high) Model output is sent to a customer but no reply guard (URL/price/promise filter) exists.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading. This lens is judge-graded: the probe only locates the candidate, the verdict needs the surrounding product behaviour.

## Fix template
Post-filter replies: strip/deny URLs not in the store's domains, replace numbers not in the catalogue, block promise phrases, fall back to a handoff message.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
