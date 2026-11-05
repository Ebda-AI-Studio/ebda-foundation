# DMARC p=none or no CAA record

Pack: cloudflare, security | Probe type: H | Source: Ebda AI Studio audit 2026-10-26 OPS-17, OPS-20

## Claim
A domain sending mail needs an enforcing DMARC policy (quarantine/reject) and a CAA record naming the allowed CAs; leftover provider records should be removed.

## Scenario
Ebda's DMARC was p=none while platform mail went out from ebda.app, there was no CAA record, and old Resend/SES DNS records remained.

## Source candidate
- (medium) DMARC policy is p=none.
- (medium) No CAA record on the apex.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Move DMARC to quarantine after monitoring, add CAA, delete unused provider records.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
