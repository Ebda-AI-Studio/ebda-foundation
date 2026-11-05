# Direct provider SDK call outside the safe-error wrapper

Pack: reliability, observability | Probe type: S | Source: Iceberg term 39 (2026-07-11)

## Claim
Every direct call to a third-party AI/SDK must go through the sanctioned wrapper so a raw provider error or stack never reaches a client UI.

## Scenario
A raw `[GoogleGenerativeAI Error 429]` was shown in merchant admin; 5 files bypassed the wrapper.

## Source candidate
- (medium) Direct provider SDK construction/call with no wrapper reference in the file.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Route every call through the wrapper that maps provider errors to a safe message and logs the original.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
