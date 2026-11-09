# Tests that assert on source text, not behaviour

Pack: cicd | Probe type: S | Source: Ebda AI Studio audit 2026-10-26 CODE-9

## Claim
A test that reads a source file and regex-matches it proves the text exists, not that the code works; it passes on dead code.

## Scenario
Many Ebda tests proved the source text or a mocked collaborator, so a green suite said nothing about behaviour.

## Source candidate
- (low) Test reads a source file and asserts on its text.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Call the function / hit the route and assert on the result.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
