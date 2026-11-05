# No runbook, on-call owner or postmortem path

Pack: observability | Probe type: J | Source: Iceberg Audit term gap (no mechanical lens before 2026-10-26) 25

## Claim
Production needs a written runbook, a named on-call owner and a postmortem habit before the first customer.

## Scenario
Nobody was on call at Ebda while Ahmad slept and alerts went to one personal inbox.

## Source candidate
- (medium) Production is documented but no runbook/on-call/postmortem exists.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading. This lens is judge-graded: the probe only locates the candidate, the verdict needs the surrounding product behaviour.

## Fix template
Add RUNBOOK.md: severity, who is paged, first-15-minutes checklist, postmortem template.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
