# Static assets config without run_worker_first for money/entitlement routes

Pack: cloudflare, money | Probe type: S | Source: Ebda master catalogue 2026-10-26 sec.7 L77

## Claim
Any route that receives money or entitlement events must be in run_worker_first, or the assets layer answers it first.

## Scenario
Ebda webhook paths could be shadowed by the assets binding until listed in run_worker_first (M-020).

## Source candidate
- (high) wrangler config binds assets but has no run_worker_first.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
List webhook and entitlement paths in run_worker_first and probe them unsigned in verify-prod.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
