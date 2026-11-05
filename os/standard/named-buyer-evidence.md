# Buyer persona with no interview evidence

Pack: business | Probe type: J | Source: Ebda AI Studio audit 2026-10-26 BIZ-8

## Claim
A target customer needs evidence: interviews, quotes or counts, not an assumption.

## Scenario
Ebda's named buyer and her numbers were guesses and nothing showed the W1 interviews happened.

## Source candidate
- (medium) Persona/ICP is defined with no interview or quote evidence.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading. This lens is judge-graded: the probe only locates the candidate, the verdict needs the surrounding product behaviour.

## Fix template
Log each interview (date, quote, number) next to the persona.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
