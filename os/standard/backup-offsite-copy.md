# Backups never leave the machine or account that holds the data

Pack: data | Probe type: S | Source: Ebda master catalogue 2026-10-26 sec.7 L08

## Claim
The system of record needs a copy off the machine and off the account.

## Scenario
Ebda had no off-machine copy of the production database and the Mac copy had gaps (M-011, M-035, M-036).

## Source candidate
- (high) Backup job found with no off-site destination.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Copy dumps to a second provider (R2/S3 in another account) and alert on a missing day.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
