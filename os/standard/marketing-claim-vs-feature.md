# Marketing promises a capability gated elsewhere

Pack: docs, business | Probe type: J | Source: Ebda AI Studio audit 2026-10-26 DOC-4

## Claim
A claim on a pricing or marketing page must hold for the plan it appears under.

## Scenario
Ebda marketed abandoned-cart recovery by SMS on Growth while the sms feature was Business-only and needed the merchant's own provider.

## Source candidate
- (medium) Marketing copy promises SMS as included without saying it needs the merchant's own provider or a higher plan.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading. This lens is judge-graded: the probe only locates the candidate, the verdict needs the surrounding product behaviour.

## Fix template
Generate plan feature lists from the registry; mark bring-your-own-provider features explicitly.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
