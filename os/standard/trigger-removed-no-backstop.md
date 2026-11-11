# Database trigger dropped with no replacing assertion

Pack: data | Probe type: S+J | Source: Ebda master catalogue 2026-10-26 sec.7 L11

## Claim
Invariants moved from database triggers into application methods need a backstop (trigger or nightly assertion), or any other path bypasses them.

## Scenario
Ebda moved journal balance, updated_at and VAT guards from Postgres triggers into repo methods (M-047).

## Source candidate
- (medium) Migration drops a trigger with no CHECK/assertion in the same file.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading. This lens is judge-graded: the probe only locates the candidate, the verdict needs the surrounding product behaviour.

## Fix template
Keep a CHECK/trigger or add a nightly assertion query that fails loud.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
