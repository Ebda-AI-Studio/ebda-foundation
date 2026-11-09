# The same price literal is hard-coded on many surfaces

Pack: docs, business | Probe type: S | Source: Ebda master catalogue 2026-10-26 sec.7 L40

## Claim
Price statements (VAT, plan names, quoted prices) are generated from one catalogue and identical on every surface.

## Scenario
Ebda's VAT presentation, plan names and quoted prices disagreed across the site, policy and help (M-027, M-080, M-109).

## Source candidate
- (medium) Price literals appear in four or more source files.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Render prices from one catalogue module; fail CI on a literal outside it.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
