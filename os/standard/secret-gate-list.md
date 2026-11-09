# Deploy secret gate list needs checking against the code

Pack: cicd | Probe type: J | Source: Ebda AI Studio audit 2026-10-26 OPS-13

## Claim
A hand-written list of required secrets drifts: it keeps retired names and misses the ones the app now needs.

## Scenario
Ebda's API deploy secret gate checked a retired secret and missed the ones the app needs, so a deploy passed the gate and booted without them.

## Source candidate
- (low) Hand-written required-secrets list found; verify each name is still read and every needed name is listed.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading. This lens is judge-graded: the probe only locates the candidate, the verdict needs the surrounding product behaviour.

## Fix template
Derive the list from the code's env schema (or fail the boot on a missing name) instead of hand-listing.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
