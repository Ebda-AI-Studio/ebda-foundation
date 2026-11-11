# Activation is defined but never emitted as an event

Pack: business, observability | Probe type: S | Source: Ebda AI Studio audit 2026-10-26 BIZ-18

## Claim
If 'activated' is the metric, the code must emit an event when it happens, or the funnel cannot be measured.

## Scenario
Ebda defined activation but did not instrument it.

## Source candidate
- (medium) 'Activation' is referenced but no activation event is emitted.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Emit track('activated') at the defined moment and chart it.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
