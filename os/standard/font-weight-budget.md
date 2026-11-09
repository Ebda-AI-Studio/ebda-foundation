# Render-blocking Google Fonts stylesheet

Pack: perf | Probe type: S | Source: Ebda AI Studio audit 2026-10-26 SEO-5

## Claim
A third-party fonts stylesheet in the head blocks render and pulls many font files; self-host subsets.

## Scenario
Ebda pages loaded Google Fonts CSS in the head and 17-20 font files (370-640 KB).

## Source candidate
- (low) Google Fonts stylesheet referenced.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Self-host woff2 subsets for the used weights, preload the primary one.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
