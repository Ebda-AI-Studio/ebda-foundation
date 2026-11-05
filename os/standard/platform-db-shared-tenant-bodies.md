# Raw tenant payloads kept in one shared database with no purge

Pack: tenancy, privacy | Probe type: J | Source: Ebda AI Studio audit 2026-10-26 DB-13

## Claim
Raw webhook/payload bodies for every tenant in one table are a blast-radius and retention problem; purge or scope them.

## Scenario
Ebda's platform D1 was one database for every tenant's directory, billing and webhook bodies.

## Source candidate
- (medium) Shared table stores raw bodies/payloads with no retention marker.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading. This lens is judge-graded: the probe only locates the candidate, the verdict needs the surrounding product behaviour.

## Fix template
Store a hash plus the fields needed, expire raw bodies, and scope per tenant.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
