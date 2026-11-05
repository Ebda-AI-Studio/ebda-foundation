# Module-level timer that is never cleared

Pack: reliability | Probe type: S | Source: Playbook sec 14 Memory-leak (setInterval CI hang)

## Claim
A setInterval at module scope keeps the process alive and leaks; clear it or unref it.

## Scenario
The a previous storefront product setInterval CI hang: a module-level timer kept every test process alive until the job timeout.

## Source candidate
- (low) Module-level setInterval with no clearInterval/unref in the file.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Start timers from an explicit start() with a matching stop(), or call .unref().

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
