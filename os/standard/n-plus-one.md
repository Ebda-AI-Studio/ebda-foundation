# Database query inside a loop over rows

Pack: reliability, data | Probe type: S | Source: Builder-reality reel pack (reel-lenses-2026-09) + playbook sec 14, L9; playbook sec 14 N+1

## Claim
A list that triggers one query per row is the works-at-100, dies-at-1000 cliff; load the relation in one query.

## Scenario
Ebda's small N+1s (DB-12): each row of a list re-queried its relation, invisible at 6 stores and linear after launch.

## Source candidate
- (medium) await on a database read inside a for/forEach/map loop (N+1).

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Use include/join or one `IN (...)` query and group in memory.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
