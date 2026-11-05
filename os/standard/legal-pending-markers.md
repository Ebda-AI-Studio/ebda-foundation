# Legal page published with unreviewed or placeholder markers

Pack: docs, privacy | Probe type: S+J | Source: Ebda AI Studio audit 2026-10-26 DOC-3

## Claim
Terms and privacy text must not ship placeholders or 'pending counsel review' clauses that look final.

## Scenario
Ebda's legal text was unreviewed by counsel and the pending-review clauses were published with their markers stripped, so they read as binding terms.

## Source candidate
- (high) Legal text carries a placeholder/pending-review marker.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading. This lens is judge-graded: the probe only locates the candidate, the verdict needs the surrounding product behaviour.

## Fix template
Gate publication of /terms and /privacy on a reviewed flag; keep markers visible until counsel signs off.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
