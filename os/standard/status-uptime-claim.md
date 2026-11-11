# Public status page shows uptime below target

Pack: business, observability | Probe type: H | Source: Ebda AI Studio audit 2026-10-26 BIZ-24

## Claim
A public uptime figure under the SLO is a launch-trust problem; fix the cause or stop publishing a misleading window.

## Scenario
Ebda's public status page showed 55.62% Storefront uptime over 90 days.

## Source candidate
- (medium) Status snapshot shows uptime below 99%.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Find the failing check (often the probe, not the service) and fix or retire it.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
