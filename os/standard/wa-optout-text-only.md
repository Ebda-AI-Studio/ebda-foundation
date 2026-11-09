# Opt-out keyword checked on text bodies only

Pack: meta-whatsapp, privacy | Probe type: S | Source: Ebda master catalogue 2026-10-26 sec.7 L74

## Claim
Opt-out detection must run on every inbound channel that can carry text (text, button title, list title, caption).

## Scenario
STOP typed as a button title or caption was not recognised, so an opted-out buyer kept receiving messages (M-060).

## Source candidate
- (high) Opt-out keyword matched without handling button/list/caption fields.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Normalise all inbound text-bearing fields before the opt-out check.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
