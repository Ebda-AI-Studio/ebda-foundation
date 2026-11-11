# Primary signup CTA opens in a new tab

Pack: frontend | Probe type: S | Source: Ebda AI Studio audit 2026-10-26 UI-15

## Claim
A signup/get-started CTA that opens a new tab breaks the funnel and the back button.

## Scenario
Ebda signup CTAs opened in a new tab.

## Source candidate
- (low) Signup/register/get-started link has target="_blank".

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Same-tab navigation for conversion links.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
