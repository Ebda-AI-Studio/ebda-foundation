# Module-level Map cache with no eviction

Pack: reliability | Probe type: S | Source: Ebda AI Studio audit 2026-10-26 BUG-13

## Claim
A module-scope Map used as a cache needs a size cap or TTL eviction, or it grows until the isolate is recycled.

## Scenario
Ebda's in-memory analytics cache never evicted expired entries.

## Source candidate
- (low) Module-level `new Map()` cache with no delete/eviction in the file.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Add maxSize with LRU eviction and sweep expired keys on write.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
