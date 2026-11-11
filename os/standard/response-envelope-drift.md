# Two response envelope shapes in one API

Pack: cicd | Probe type: S | Source: Ebda master catalogue 2026-10-26 sec.7 L48

## Claim
Keep one response envelope ({ success, data | error }) and typed surfaces on LLM-write paths.

## Scenario
Ebda had two response shapes beside the standard envelope (M-156, M-157).

## Source candidate
- (low) Both a { success: } envelope and a bare { ok: true } response are used.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Pick the envelope, wrap the outliers, lint for raw res.json({ ok:.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
