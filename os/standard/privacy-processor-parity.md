# A processor the code uses is missing from the privacy policy

Pack: privacy, docs | Probe type: S+J | Source: Ebda AI Studio audit 2026-10-26 DOC-2, DOC-11

## Claim
Every third-party processor in the dependencies must be named in the published privacy policy with its purpose and retention.

## Scenario
Ebda's privacy policy omitted processors and retention that the internal data map recorded, and the approved Customer Intelligence / consent clauses were not in the published text.

## Source candidate
- (high) A processor dependency is not named in the privacy policy.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading. This lens is judge-graded: the probe only locates the candidate, the verdict needs the surrounding product behaviour.

## Fix template
Generate the policy's processor table from the data map; fail CI when a dependency has no row.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
