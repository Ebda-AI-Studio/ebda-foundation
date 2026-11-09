# Physical left/right utilities in RTL-served UI

Pack: frontend | Probe type: S | Source: Ebda AI Studio audit 2026-10-26 UI-13, UI-1

## Claim
In an RTL-served UI use logical properties (ms-/me-/ps-/pe-/text-start); ml-/pr-/text-left break the mirrored layout.

## Scenario
Ebda admin RTL and type-size leftovers: physical spacing and alignment survived next to Arabic-default screens.

## Source candidate
- (medium) Physical ml-/mr-/pl-/pr-/text-left/text-right in a file that handles RTL.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Replace ml/mr/pl/pr with ms/me/ps/pe and text-left/right with text-start/end.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
