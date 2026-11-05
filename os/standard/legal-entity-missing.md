# Legal notice names no registered entity

Pack: docs, business | Probe type: S | Source: Ebda AI Studio audit 2026-10-26 DOC-12, BIZ-1

## Claim
The legal notice must name the registered entity, commercial register, tax number and address.

## Scenario
Ebda's legal notice named no registered entity, commercial register, tax number or address; the entity did not exist yet and that blocked charging, invoicing, Meta and Kashier.

## Source candidate
- (high) Legal notice/terms found with no registered entity, register number, tax number or address.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Register the entity, then publish its details on the legal notice and in invoices.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
