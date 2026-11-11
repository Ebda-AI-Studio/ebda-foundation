---
sources: mypovonai-software-layer-tenant-resolver-default
upstream: voidengineer-911/mypovonai-learn
---

# Tenant resolver fail closed

## Source candidate
Tenant/store resolver functions must not fall back to the first row when resolution fails.

The probe is a bounded lexical source check. It reports candidates with file/line evidence and deliberately does not claim that local guard names prove the guard is effective. A judge must inspect reachability, middleware, imports and framework semantics before grading. Runtime configuration and database state are not inferred.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
