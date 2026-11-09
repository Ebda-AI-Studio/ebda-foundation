# .env.example does not list the env names the code reads

Pack: cicd, docs | Probe type: S | Source: Ebda AI Studio audit 2026-10-26 OPS-14, DOC-13

## Claim
Every process.env name the code reads is documented in .env.example (or a schema), or a new deploy boots half-configured.

## Scenario
Ebda's .env.example files did not match what the code read or what production had; docs/ENVIRONMENT.md was missing 70+ names and still described the retired Railway/Inngest/Redis path.

## Source candidate
- (medium) Env names read by the code are missing from .env.example.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Generate .env.example from the Zod env schema and fail CI when they differ.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
