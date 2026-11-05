# fn-map / control matrix points at test files that do not exist

Pack: cicd | Probe type: S | Source: Ebda master catalogue 2026-10-26 sec.7 L12

## Claim
An evidence pointer must resolve: CI asserts the file exists, and static evidence is not 'wired'.

## Scenario
Ebda's fn-map.json pointed at 17 contract-test files that exist on no branch (M-045, M-105).

## Source candidate
- (medium) A fn-map/control-matrix entry names a test file that does not exist.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Fail CI when a mapped path is missing; generate the map from the filesystem.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
