# Single-region dependency not named

Pack: reliability | Probe type: J | Source: Iceberg Audit term gap (no mechanical lens before 2026-10-26) 20

## Claim
The database, queue and auth each live somewhere; the docs must name the region and the accepted failure mode.

## Scenario
Ebda's database compute and queues sit in one region on one provider with no stated failover.

## Source candidate
- (low) Database/queue is documented with no region or failover statement.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading. This lens is judge-graded: the probe only locates the candidate, the verdict needs the surrounding product behaviour.

## Fix template
Write the region, the failover (or the accepted outage) and the recovery time per dependency.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
