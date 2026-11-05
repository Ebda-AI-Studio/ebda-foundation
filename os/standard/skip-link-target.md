# Skip link points at an id that does not exist

Pack: frontend | Probe type: S | Source: Ebda AI Studio audit 2026-10-26 UI-4

## Claim
A 'skip to content' link must target an element id that exists on the page.

## Scenario
Ebda admin login had no landmarks and its skip link pointed at a missing id, so keyboard users skipped nothing.

## Source candidate
- (low) Skip link href targets an id that exists nowhere in the sources.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Add id="main-content" on <main> (and a <main> landmark) or fix the href.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
