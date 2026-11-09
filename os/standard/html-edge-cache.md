# HTML never served from the edge cache

Pack: perf | Probe type: H | Source: Ebda AI Studio audit 2026-10-26 SEO-2

## Claim
Public storefront HTML should hit the edge cache on a repeat fetch; a cold render of 2-11 s on every view loses buyers.

## Scenario
Ebda storefront HTML was never edge-cached and cold hits took 2-11 s.

## Source candidate
- (medium) Second HTML fetch shows no edge cache hit.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Cache rules with tag purge on publish; stale-while-revalidate.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
