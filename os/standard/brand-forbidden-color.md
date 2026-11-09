# A brand-forbidden colour class is in use

Pack: frontend | Probe type: S | Source: Ebda AI Studio audit 2026-10-26 UI-14

## Claim
A brand rule such as 'no orange' needs a mechanical check, or it drifts class by class.

## Scenario
Ebda's brand rule is no orange; two true orange classes were still in the admin.

## Source candidate
- (low) A class listed in .fleet-forbidden-classes.txt is used.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Put the forbidden classes in .fleet-forbidden-classes.txt and swap the tokens.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
