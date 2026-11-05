# Upload type decided by the client-declared MIME

Pack: security, meta-whatsapp | Probe type: S | Source: Ebda AI Studio audit 2026-10-26 SEC-12

## Claim
The Content-Type a client declares is not evidence of the bytes; sniff the content before accepting or forwarding it.

## Scenario
Ebda WhatsApp outbound media upload trusted the declared MIME type, so a script could be sent as an image.

## Source candidate
- (medium) Allowlist check runs against the client-declared MIME type, with no byte sniffing.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Sniff magic bytes (file-type or manual signatures) and allowlist.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
