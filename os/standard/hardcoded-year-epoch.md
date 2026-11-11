# Footer year computed from an unset date or hard-coded

Pack: frontend | Probe type: S | Source: Ebda AI Studio audit 2026-10-26 UI-2

## Claim
A footer year must come from the current date, never from a missing timestamp (1970) or a literal.

## Scenario
The Ebda status page footer said '© 1970'.

## Source candidate
- (low) Year derived from new Date(0/undefined/null/build timestamp).
- (low) Copyright year is a literal that will go stale.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Use new Date().getFullYear() at render time.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
