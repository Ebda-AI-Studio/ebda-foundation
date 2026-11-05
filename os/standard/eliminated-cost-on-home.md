# Home page states no eliminated cost in the buyer's currency

Pack: business | Probe type: J | Source: Ebda AI Studio audit 2026-10-26 BIZ-7, BIZ-9

## Claim
The first screen should state the cost the buyer stops paying, as a number in their currency.

## Scenario
Ebda's home page did not state the eliminated EGP/month cost.

## Source candidate
- (medium) Home/hero found with no currency amount.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading. This lens is judge-graded: the probe only locates the candidate, the verdict needs the surrounding product behaviour.

## Fix template
Lead the hero with the monthly saving for the named buyer.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
