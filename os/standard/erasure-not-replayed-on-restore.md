# Erasure leaves no durable record that a restore re-applies

Pack: privacy, data | Probe type: S+J | Source: Ebda master catalogue 2026-10-26 sec.7 L36

## Claim
Every erasure writes a durable, replayable record that a restore re-applies, or restoring a backup resurrects erased people.

## Scenario
Ebda erasures were not recorded anywhere a restore could replay (M-093).

## Source candidate
- (high) Erasure code exists with no tombstone/ledger/replay.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading. This lens is judge-graded: the probe only locates the candidate, the verdict needs the surrounding product behaviour.

## Fix template
Keep an erasure ledger outside the restored database and replay it after every restore.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
