# Source file over 1500 lines

Pack: cicd | Probe type: S | Source: Ebda AI Studio audit 2026-10-26 CODE-3, CODE-18

## Claim
Revenue-path logic in a 1500+ line file or method cannot be reviewed or tested in pieces.

## Scenario
Ebda revenue-path logic lived in methods of 500 to 1535 lines and a 2816-line component; the WhatsApp Durable Object was 2112 lines.

## Source candidate
- (low) Source file exceeds 1500 lines.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Split by responsibility, one behaviour per file, with tests at the seams.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
