# A model is read everywhere and written nowhere

Pack: data | Probe type: S | Source: Ebda AI Studio audit 2026-10-26 CODE-8

## Claim
A table/model with readers but no create/update path is either dead or filled by a hidden process.

## Scenario
Ebda's ReorderRule had readers everywhere and no writer, API or UI.

## Source candidate
- (low) Model has find*/count callers and no create/update/upsert caller.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Add the writer (and its UI) or delete the model and its readers.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
