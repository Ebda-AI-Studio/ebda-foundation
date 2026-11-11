# Marketing site has no analytics or ad pixel

Pack: business, privacy | Probe type: S | Source: Ebda AI Studio audit 2026-10-26 BIZ-26

## Claim
Without a consent-gated analytics tag the funnel and any ad campaign are blind.

## Scenario
Ebda's marketing site carried no analytics or ad pixel, so ads readiness was incomplete.

## Source candidate
- (low) Site layout exists but no analytics tag is referenced.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Add a consent-gated analytics tag and a conversion event.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
