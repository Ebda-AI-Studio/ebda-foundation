# Compiled .js committed beside its .ts source

Pack: cicd | Probe type: S | Source: Ebda AI Studio audit 2026-10-26 CODE-14

## Claim
A .js next to a same-named .ts in src is a stale build artifact that can shadow the source or run old logic.

## Scenario
Ebda had stale compiled files committed inside src, one with an unguarded Prisma client.

## Source candidate
- (low) Compiled .js committed beside a .ts of the same name.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Delete the compiled file and ignore the output directory.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
