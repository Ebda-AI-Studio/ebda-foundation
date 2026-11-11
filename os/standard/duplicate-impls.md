# The same helper implemented in several files

Pack: cicd | Probe type: S | Source: Ebda AI Studio audit 2026-10-26 CODE-7, CODE-10

## Claim
Three or more definitions of slugify / normalizePhone / formatMoney drift apart and break on the first non-ASCII input.

## Scenario
Ebda had eight slug implementations; the blog slug field could not take a hyphen and Arabic titles produced an empty slug. Phone normalisation existed in two repos with no shared test vector.

## Source candidate
- (low) Helper defined in three or more files.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
One shared module with test vectors (Arabic, hyphen, empty); import it everywhere.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
