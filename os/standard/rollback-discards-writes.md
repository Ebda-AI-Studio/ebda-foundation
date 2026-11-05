# Backend flip/rollback with no check for writes made since the flip

Pack: data, reliability | Probe type: S+J | Source: Ebda master catalogue 2026-10-26 sec.7 L09

## Claim
A rollback path must detect writes made since the flip and replay them verified, or refuse.

## Scenario
`flip-backend.mjs --to pg` rolled back with no guard against writes already made on the Durable Object side (M-013).

## Source candidate
- (high) Rollback/flip script has no guard that detects writes since the flip.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading. This lens is judge-graded: the probe only locates the candidate, the verdict needs the surrounding product behaviour.

## Fix template
Compare change counters/timestamps before flipping back; refuse or replay.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
