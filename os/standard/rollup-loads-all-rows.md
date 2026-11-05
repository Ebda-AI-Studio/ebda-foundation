# Nightly rollup loads a tenant's whole history into memory

Pack: data, reliability | Probe type: S | Source: Ebda AI Studio audit 2026-10-26 DB-6

## Claim
A rollup/cron that findMany()s every row of a tenant then reduces in application code will OOM at scale; aggregate in SQL or page.

## Scenario
Ebda's nightly analytics rollups loaded every paid order of a store into memory.

## Source candidate
- (medium) findMany with only a tenant filter (no take/cursor) in a rollup/cron file.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
SELECT SUM/COUNT ... GROUP BY in SQL, or cursor-page the rows.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
