# Customer data sent to an LLM endpoint the tenant chooses

Pack: privacy, ai-safety | Probe type: S | Source: Ebda AI Studio audit 2026-10-26 SEC-9

## Claim
If a tenant can set the LLM base URL or provider, buyer messages and order data leave the platform to a destination nobody reviewed.

## Scenario
Ebda WhatsApp AI agent sent buyer messages and order status to a merchant-chosen third-party LLM endpoint.

## Source candidate
- (high) LLM client baseURL/endpoint comes from tenant/merchant configuration with no provider allowlist.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Allowlist providers server-side, require a DPA flag per provider, redact PII before the call.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
