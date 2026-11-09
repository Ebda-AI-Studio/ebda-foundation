# External API integration with no recorded live proof

Pack: meta-whatsapp, money | Probe type: J | Source: Ebda master catalogue 2026-10-26 sec.7 L86

## Claim
External contracts (Meta Graph, Embedded Signup, unverified payment providers, refunds) get one recorded live proof before the gate flips.

## Scenario
Ebda's WhatsApp send path was only proven against a stubbed Meta Graph and provider adapters used doc-built fixtures (M-059).

## Source candidate
- (medium) Integration code exists but no live-proof/contract-test record is documented.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading. This lens is judge-graded: the probe only locates the candidate, the verdict needs the surrounding product behaviour.

## Fix template
Run each integration once against the real sandbox and record the result in docs.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
