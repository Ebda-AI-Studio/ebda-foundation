# Inline link told apart from text by colour alone

Pack: frontend | Probe type: S | Source: Ebda AI Studio audit 2026-10-26 UI-5

## Claim
WCAG 1.4.1: a link inside body text needs an underline or another non-colour cue.

## Scenario
Ebda admin login's 'create your store' link differed from the text only by colour.

## Source candidate
- (medium) Link styled with a text colour class and no underline.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Add underline (or a visible affordance) to inline links.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
