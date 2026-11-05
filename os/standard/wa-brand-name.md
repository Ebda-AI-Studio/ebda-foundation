# Product name begins or ends with WhatsApp

Pack: meta-whatsapp | Probe type: S+J | Source: Ebda AI Studio audit 2026-10-26 BIZ-6

## Claim
Meta's brand rules do not allow a product or business name that contains WhatsApp as its own brand element.

## Scenario
The product name 'Ebda WhatsApp' conflicted with Meta's brand rules and the rename decision was still open.

## Source candidate
- (medium) name/brand/title string combines WhatsApp with a brand word.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading. This lens is judge-graded: the probe only locates the candidate, the verdict needs the surrounding product behaviour.

## Fix template
Name the product after your brand (for example 'Ebda Chat') and describe it as 'for WhatsApp'.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
