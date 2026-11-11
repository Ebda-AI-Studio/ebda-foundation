# Type-safety escape hatches concentrated in one file

Pack: cicd | Probe type: S | Source: Ebda AI Studio audit 2026-10-26 CODE-17

## Claim
Ten or more `as any` / @ts-ignore / @ts-expect-error in one file means the type boundary there is decorative.

## Scenario
Ebda's MCP tools concentrated the type-safety escape hatches.

## Source candidate
- (low) File holds ten or more type escape hatches (as any, @ts-ignore, @ts-expect-error).

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Type the boundary once (Zod parse at the edge) and delete the casts.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
