# WhatsApp launch with no verification plan documented

Pack: meta-whatsapp, business | Probe type: J | Source: Ebda AI Studio audit 2026-10-26 BIZ-5, BIZ-20

## Claim
Meta business verification needs a registered entity and takes time; a WhatsApp launch plan must name that chain and its owner.

## Scenario
Ebda WhatsApp launch depended on a Meta verification chain nobody could start until the legal entity existed, and the own-number path was blocked for the beachhead.

## Source candidate
- (medium) WhatsApp docs exist but no business-verification plan is mentioned.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading. This lens is judge-graded: the probe only locates the candidate, the verdict needs the surrounding product behaviour.

## Fix template
Document the chain (entity, commercial register, Meta verification, display name) with dates and an owner.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
