# Text dimmed with opacity below contrast

Pack: frontend | Probe type: S | Source: Ebda master catalogue 2026-10-26 sec.7 L55

## Claim
Dimmed or inactive states still meet 4.5:1 contrast.

## Scenario
Ebda's inactive story steps on the English home failed contrast (M-075).

## Source candidate
- (low) Text colour with 30-50% alpha or opacity-30/40.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Dim by token (a muted colour that passes), not by opacity-30/40.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
