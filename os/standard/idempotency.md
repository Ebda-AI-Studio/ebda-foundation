---
sources: mypovonai-software-layer-idempotency
upstream: voidengineer-911/mypovonai-learn
---

# Payment and webhook deduplication

## Source candidate
Payment/webhook route writes require an explicit idempotency/deduplication claim in the handler.

The probe is a bounded lexical source check. It reports candidates with file/line evidence and deliberately does not claim that local guard names prove the guard is effective. A judge must inspect reachability, middleware, imports and framework semantics before grading. Runtime configuration and database state are not inferred.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
