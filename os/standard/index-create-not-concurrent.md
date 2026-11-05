# CREATE INDEX on Postgres without CONCURRENTLY

Pack: data | Probe type: S | Source: Ebda master catalogue 2026-10-26 sec.7 L83

## Claim
Down migrations or additive-only enforcement, and CONCURRENTLY for big tables.

## Scenario
Ebda built indexes with plain CREATE INDEX on large tables, locking writes (M-139, M-098).

## Source candidate
- (medium) CREATE INDEX without CONCURRENTLY.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Use CREATE INDEX CONCURRENTLY outside a transaction.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
