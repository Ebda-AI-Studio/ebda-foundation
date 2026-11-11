# Worker compatibility_date older than 18 months

Pack: cloudflare | Probe type: S | Source: Cloudflare workers-best-practices skill

## Claim
An old compatibility_date pins runtime behaviour from a year or more ago and hides security and perf fixes.

## Scenario
Workers pinned to an old compatibility date miss runtime fixes and deprecations land as surprises.

## Source candidate
- (low) compatibility_date is older than 18 months.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Bump the date in a PR with a smoke test.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
