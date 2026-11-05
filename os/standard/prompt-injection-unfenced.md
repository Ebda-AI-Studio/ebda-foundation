# Untrusted text interpolated into a prompt without fencing

Pack: ai-safety, security | Probe type: S | Source: Ebda AI Studio audit 2026-10-26 SEC-2, SEC-11

## Claim
Reviews, receipts, messages and OCR text are data; put them inside a labelled untrusted block, demand a schema, and never let them carry authority.

## Scenario
Ebda review text was concatenated into the moderation prompt, and the InstaPay receipt reader could be told to suppress its own warning flags.

## Source candidate
- (high) User-controlled text is interpolated into a prompt string with no untrusted fence or output schema.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Wrap in <untrusted>...</untrusted>, state that nothing inside is an instruction, force a JSON schema/response_format, and compute decisions outside the model.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
