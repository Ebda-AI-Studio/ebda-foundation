# Hono app without onError, so errors never reach Sentry

Pack: observability | Probe type: S | Source: Ebda master catalogue 2026-10-26 sec.7 L78

## Claim
Framework-swallowed errors need onError and Durable Object instrumentation so the error tracker sees them.

## Scenario
Ebda's Hono routes converted thrown errors into 500s that Sentry never saw (M-019).

## Source candidate
- (medium) Hono app is created with no onError handler.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Add app.onError that reports to Sentry; wrap Durable Object classes with the Sentry wrapper.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
