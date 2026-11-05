# Bulk export route without a dedicated permission

Pack: security, privacy | Probe type: S+J | Source: Ebda AI Studio audit 2026-10-26 SEC-14

## Claim
A route that exports all customers must require its own permission and write an audit row, not just 'is staff'.

## Scenario
Any Ebda staff account could download every customer's PII in one call.

## Source candidate
- (high) Export route has no explicit permission check or audit write.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading. This lens is judge-graded: the probe only locates the candidate, the verdict needs the surrounding product behaviour.

## Fix template
Add an export permission, check it in the handler, and audit-log each export.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
