# Competitor claim with no verification date

Pack: business, docs | Probe type: J | Source: Ebda master catalogue 2026-10-26 sec.7 L85

## Claim
Competitor and market claims carry a verification date and a human-browser check.

## Scenario
Ebda's compare pages rested on unverified research about five rivals (M-083).

## Source candidate
- (low) Competitor comparison text with no verification date.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading. This lens is judge-graded: the probe only locates the candidate, the verdict needs the surrounding product behaviour.

## Fix template
Add 'verified on <date>' next to each claim and re-check quarterly.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
