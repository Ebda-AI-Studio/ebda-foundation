# Text set below 12px

Pack: frontend | Probe type: S | Source: Ebda AI Studio audit 2026-10-26 UI-11

## Claim
Real copy under 12px fails legibility and zoom expectations.

## Scenario
Ebda's hero mock-up text was 8-11px.

## Source candidate
- (low) Font size of 8-11px.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Raise to 12px or hide decorative mock-ups from the accessibility tree.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
