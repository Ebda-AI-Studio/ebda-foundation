# Prepaid wallet exposed to FX with no buffer

Pack: meta-whatsapp, money | Probe type: J | Source: Ebda AI Studio audit 2026-10-26 BIZ-16

## Claim
A local-currency wallet that pays Meta in USD/EUR needs an FX buffer or repricing rule.

## Scenario
Ebda's WhatsApp wallet exposed it to FX movement with an unset buffer.

## Source candidate
- (medium) Wallet/conversation pricing in a foreign currency with no FX buffer documented.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading. This lens is judge-graded: the probe only locates the candidate, the verdict needs the surrounding product behaviour.

## Fix template
Set a documented FX margin and a reprice trigger.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
