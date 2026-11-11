# Public read API slow under a light client

Pack: perf, reliability | Probe type: H | Source: Ebda AI Studio audit 2026-10-26 SEO-3

## Claim
Public read endpoints should answer p95 under 500 ms and not shed 503 under a single light client.

## Scenario
Ebda's public read API took about 1 s per call and returned 503 OVERLOADED under one light client.

## Source candidate
- (medium) API latency snapshot p95 is 500 ms or more.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Edge-cache reads, pool the database, add per-key concurrency limits.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
