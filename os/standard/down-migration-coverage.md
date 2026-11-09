# Most migrations have no down path

Pack: data | Probe type: S | Source: Ebda AI Studio audit 2026-10-26 DB-11

## Claim
A migration set where most migrations have no down (or documented forward-fix) cannot be rolled back.

## Scenario
172 of Ebda's 215 Postgres migrations had no down, six of them destructive.

## Source candidate
- (medium) Fewer than half of the migrations have a down path.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Add down.sql (or a written forward-only ruling) for every destructive migration at least.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
