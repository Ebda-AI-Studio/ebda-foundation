# Free-form WhatsApp send with no 24-hour window or template path

Pack: meta-whatsapp | Probe type: S | Source: Meta WhatsApp Business policy (24 h customer service window)

## Claim
Outside the 24-hour customer-service window only approved template messages may be sent; code that sends free text must check the window.

## Scenario
A free-text send after the window is rejected by Meta and counts against quality rating.

## Source candidate
- (high) WhatsApp Graph send exists with no 24h-window or template fallback.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Check last inbound timestamp; fall back to a template message.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
