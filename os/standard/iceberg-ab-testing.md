# No way to run an experiment without a deploy

Pack: business | Probe type: J | Source: Iceberg Audit term gap (no mechanical lens before 2026-10-26) 37

## Claim
Pricing and onboarding copy are hypotheses; there must be a way to split traffic and read the result without shipping code.

## Scenario
Ebda's pricing page, trial length and home copy are all guesses with no experiment mechanism.

## Source candidate
- (low) Pricing/hero code exists but no experiment/variant mechanism is referenced.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading. This lens is judge-graded: the probe only locates the candidate, the verdict needs the surrounding product behaviour.

## Fix template
Add a feature-flag/experiment service (variant assignment + conversion event).

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
