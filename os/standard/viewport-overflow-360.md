# Page wider than a 360px phone

Pack: frontend | Probe type: H | Source: Ebda AI Studio audit 2026-10-26 UI-1, UI-3

## Claim
At a 360px viewport the document must not scroll horizontally (WCAG 1.4.10 reflow).

## Scenario
Ebda's Arabic marketing site was wider than a 360px phone (hero, header CTA and headings clipped) and the status page overflowed at 360px in English.

## Source candidate
- (high) Browser snapshot shows horizontal overflow at 360px.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Find the widest element with a browser overflow audit and constrain it; test both locales.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
