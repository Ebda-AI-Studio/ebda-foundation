# Alert transport that silently no-ops when its secret is missing

Pack: observability | Probe type: S | Source: Ebda master catalogue 2026-10-26 sec.7 L04

## Claim
An alert transport needs two independent channels and must fail boot or deploy when none is configured; a no-op-on-missing-secret transport fails open.

## Scenario
Ebda's alert bridge returned quietly when its token was unset, so production errors reached nobody (M-009, M-018, M-019).

## Source candidate
- (high) Alert/notify code returns silently when its webhook/token env is unset.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Throw at boot when no channel is configured; add a second independent channel.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
