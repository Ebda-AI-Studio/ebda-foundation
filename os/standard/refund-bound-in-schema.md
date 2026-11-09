# Refunded amount not bounded by the charge in the schema

Pack: money, data | Probe type: S | Source: Ebda AI Studio audit 2026-10-26 DB-9

## Claim
The database, not only the app, must refuse refunded > charged.

## Scenario
Ebda WhatsApp D1 stored refunded amounts with no CHECK, so a double-submit could record more refunded than charged.

## Source candidate
- (medium) Schema stores a refunded amount with no CHECK bounding it by the charge.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
CHECK (refunded_amount <= amount) or a trigger.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
