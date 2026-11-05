---
sources: mypovonai-software-layer-i18n-parity
upstream: voidengineer-911/mypovonai-learn
---

# Referenced locale key coverage

## Source candidate
Literal translation keys referenced by source must exist in at least one EN/AR JSON catalog, even when both catalogs omit them.

The probe is a bounded lexical source check. It reports candidates with file/line evidence and deliberately does not claim that local guard names prove the guard is effective. A judge must inspect reachability, middleware, imports and framework semantics before grading. Runtime configuration and database state are not inferred.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
