# UI or docs name a plan the registry does not sell

Pack: docs, business | Probe type: S | Source: Ebda AI Studio audit 2026-10-26 DOC-6, DOC-7

## Claim
Plan names shown in upgrade prompts, docs and matrices must be exactly the plans in the plan registry.

## Scenario
Ebda in-app upgrade prompts named Starter / Professional / Enterprise, which were not sold; docs/business/plan-feature-matrix.md stated the opposite of the current model.

## Source candidate
- (medium) Plan name used in UI/docs is absent from the plan registry.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Generate the matrix and the prompts from the registry (code is source of truth); fail CI on a name that is not in it.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
