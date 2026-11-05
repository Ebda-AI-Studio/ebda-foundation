# Table with personal columns missing from every retention/erasure doc

Pack: privacy, data | Probe type: S+J | Source: Ebda master catalogue 2026-10-26 sec.7 L34

## Claim
Every table with personal columns ships with a retention row and an erasure-registry entry.

## Scenario
Ebda tables holding phone, address and email had no retention row or erasure entry (M-025, M-094).

## Source candidate
- (high) Table with personal columns is named in no retention/erasure document.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading. This lens is judge-graded: the probe only locates the candidate, the verdict needs the surrounding product behaviour.

## Fix template
Add the table to the data map with a retention window and to the erasure registry; test it over the schema.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
