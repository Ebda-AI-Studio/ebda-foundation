# Append-only table with no retention job

Pack: privacy, data | Probe type: S | Source: Ebda AI Studio audit 2026-10-26 DB-10

## Claim
Events/log/status tables need a retention window enforced by a delete job or TTL, or they grow without bound and hold PII forever.

## Scenario
Ebda WhatsApp DO: message_status_events and store_orders grew without retention.

## Source candidate
- (medium) Events/logs table is created but no retention/delete job exists.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Add a scheduled DELETE ... WHERE created_at < now() - interval, and document the window.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
