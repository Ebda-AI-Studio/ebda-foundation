# Bulk job with a single checkpoint step

Pack: reliability | Probe type: S | Source: Iceberg term 40 (2026-07-11)

## Claim
A worker that loops over N items must checkpoint per batch (step.run per chunk), so a crash resumes instead of restarting.

## Scenario
8 of 10 a previous storefront product bulk-ai sweeps had a single mark-running step; one died at 130/156 after 71 minutes with zero resume.

## Source candidate
- (medium) Function with a loop has at most one step.run checkpoint.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Wrap each chunk in step.run('chunk-N') with its own idempotent writes.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
