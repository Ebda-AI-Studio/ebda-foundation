# Many cron triggers on one small database

Pack: cloudflare, reliability | Probe type: S+J | Source: Ebda AI Studio audit 2026-10-26 OPS-19

## Claim
A database with a small compute floor plus dozens of crons and queue consumers on it pins the compute and queues work behind itself.

## Scenario
Ebda's production database compute was pinned at 0.25 CU with 28 cron jobs and queue consumers on it.

## Source candidate
- (medium) wrangler config schedules 20 or more cron triggers.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading. This lens is judge-graded: the probe only locates the candidate, the verdict needs the surrounding product behaviour.

## Fix template
Stagger or merge crons, move heavy reads to replicas or analytics, size compute to the schedule.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
