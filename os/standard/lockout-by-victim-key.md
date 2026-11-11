# Account lockout keyed only by the victim's identifier

Pack: security | Probe type: S | Source: Ebda AI Studio audit 2026-10-26 SEC-3

## Claim
A failed-login lockout counter keyed only by email/username lets anyone lock any account out on purpose.

## Scenario
Five bad passwords against any address on Ebda accounts locked the real owner out; the counter never looked at the caller's IP or device.

## Source candidate
- (high) Failed-login lockout counter is keyed by the account identifier alone, so an attacker can lock any user out.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Key the counter by account plus caller (IP/device), back off per caller, and give the owner a recovery path that does not depend on the counter.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
