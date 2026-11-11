# Model calls with no per-customer turn cap or quota

Pack: ai-safety, reliability | Probe type: S | Source: Ebda master catalogue 2026-10-26 sec.7 L76

## Claim
Per-customer AI turn caps, per-principal API rate limits and new-workspace marketing caps bound abuse and cost.

## Scenario
Ebda's WhatsApp agent had no per-customer turn cap, so one chatty or hostile buyer could burn the AI budget (M-090, M-091, M-092).

## Source candidate
- (medium) LLM calls exist with no turn cap/quota/rate-limit reference.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Cap turns per customer per day and alert at 80% of the budget.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
