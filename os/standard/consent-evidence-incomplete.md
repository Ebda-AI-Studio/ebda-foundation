# Consent row stores no wording, version or attestor

Pack: privacy | Probe type: S | Source: Ebda master catalogue 2026-10-26 sec.7 L80

## Claim
Consent evidence stores who attested, which wording, and when.

## Scenario
Ebda recorded a boolean consent flag without the wording, policy version or the person who attested (M-089).

## Source candidate
- (medium) Consent record created without wording/version/attestor fields.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Store policyVersion, wording id, attestedBy and timestamp.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
