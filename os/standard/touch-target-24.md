# Interactive element smaller than 24px

Pack: frontend | Probe type: S | Source: Ebda AI Studio audit 2026-10-26 UI-10

## Claim
WCAG 2.2 AA 2.5.8: pointer targets must be at least 24x24 CSS px.

## Scenario
Ebda storefronts had small targets under 24px.

## Source candidate
- (medium) Button/link sized below 24px (Tailwind h-1..h-5 / size-1..size-5).

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Use h-6 w-6 or larger (or padding) on buttons and links.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
