# Business-day windows built on UTC midnight

Pack: reliability, money | Probe type: S | Source: Ebda AI Studio audit 2026-10-26 BUG-10

## Claim
'Today' and 'this month' for a local-time business must use the business timezone, not UTC midnight.

## Scenario
Ebda dashboard 'this month' windows started at UTC midnight, not Cairo midnight, so late-night orders landed in the wrong day.

## Source candidate
- (medium) Window bounds use setUTCHours(0,0,0)/Date.UTC(...,1) with no timezone handling.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Compute window bounds with the store's IANA zone (Intl/Temporal/date-fns-tz).

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
