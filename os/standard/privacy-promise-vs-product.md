# Legal text promises deletion the product does not perform

Pack: privacy, docs | Probe type: S+J | Source: Ebda AI Studio audit 2026-10-26 DOC-1

## Claim
Every deletion/closure promise in the legal pages needs a route or job that does it, within the stated time.

## Scenario
Ebda's legal pages promised merchant self-serve account closure and a 90-day store deletion; the product did neither.

## Source candidate
- (critical) Legal text promises deletion/closure but no delete route or purge job exists in the sources.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading. This lens is judge-graded: the probe only locates the candidate, the verdict needs the surrounding product behaviour.

## Fix template
Build the closure flow and purge job, or reword the page to what exists.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
