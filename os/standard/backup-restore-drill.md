# Backups exist but nothing restores and compares them

Pack: data, reliability | Probe type: S | Source: Ebda master catalogue 2026-10-26 sec.7 L07

## Claim
A backup is not a backup until a scheduled job restores it and compares counts, and every system of record is in the sweep.

## Scenario
Ebda's identity D1 was not in the backup sweep and no job restored any dump (M-051, M-097, M-011).

## Source candidate
- (high) Backup job exists with no restore/verify step.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Add a weekly restore-and-count job and list every datastore in the sweep.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
