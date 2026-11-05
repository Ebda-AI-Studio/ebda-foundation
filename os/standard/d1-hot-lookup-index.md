# Tenant-keyed table with no index on the tenant column

Pack: data | Probe type: S | Source: Ebda AI Studio audit 2026-10-26 DB-8

## Claim
Every table looked up by workspace/tenant/store id needs an index starting with that column.

## Scenario
Ebda WhatsApp D1: hot lookups by workspace_id had no index.

## Source candidate
- (medium) SQL schema has a workspace/tenant/store column but no index on it.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
CREATE INDEX idx_<t>_workspace ON <t>(workspace_id, ...).

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
