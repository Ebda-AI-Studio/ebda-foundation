# Pricing documented with no cost or margin model

Pack: money, business | Probe type: J | Source: Ebda AI Studio audit 2026-10-26 BIZ-11..16

## Claim
Every plan price needs a written unit cost (AI per reply, processing fees, FX) and a margin, or the loss threshold is a guess.

## Scenario
Ebda had no cost model in the repo; per-plan margins were unwritten, the WhatsApp loss threshold was 2-3x off, 'AI credit' was undefined and card fees were not modelled.

## Source candidate
- (medium) Pricing/plan documents exist but none mention margin, COGS or a cost model.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading. This lens is judge-graded: the probe only locates the candidate, the verdict needs the surrounding product behaviour.

## Fix template
Add docs/business/cost-model.md: per-plan COGS, processing fee, FX buffer, margin, break-even usage.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
