# Billing anchor advanced by adding a month to the previous date

Pack: money, reliability | Probe type: S | Source: Ebda AI Studio audit 2026-10-26 BUG-11

## Claim
Advancing a billing date with setMonth(+1) from the last date drifts permanently after a short month (31 Jan -> 28 Feb -> 28 Mar).

## Scenario
Ebda platform billing anchor drifted for good after a short month.

## Source candidate
- (medium) Date advanced with setMonth(getMonth()+1) from the previous date.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Derive each period from the original anchor day, clamped to month end.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
