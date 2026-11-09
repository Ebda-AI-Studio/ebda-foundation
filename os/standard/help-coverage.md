# Shipped features without a help article

Pack: docs, business | Probe type: S+J | Source: Ebda AI Studio audit 2026-10-26 DOC-8, BIZ-23

## Claim
A help centre should have roughly one article per shipped merchant feature, including billing, trial and cancellation.

## Scenario
Ebda's help centre documented 16 topics while most shipped merchant features had no article and WhatsApp had none.

## Source candidate
- (low) Help articles are under a fifth of the route groups.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading. This lens is judge-graded: the probe only locates the candidate, the verdict needs the surrounding product behaviour.

## Fix template
Add an article per feature in the same PR that ships it (documentation parity).

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
