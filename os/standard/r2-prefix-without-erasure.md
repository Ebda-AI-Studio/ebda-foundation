# Object-storage key prefix written with no erasure owner or lifecycle

Pack: privacy, cloudflare | Probe type: S | Source: Ebda master catalogue 2026-10-26 sec.7 L37

## Claim
Every R2 key prefix a feature writes must be in an erasure map with a delete owner or lifecycle rule.

## Scenario
Ebda wrote buyer images and receipts to R2 prefixes that the erasure path never listed (M-021, M-042, M-094).

## Source candidate
- (medium) R2 put() to a prefix with no erasure/lifecycle reference.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Register each prefix with its owner and purge rule; test with one object per prefix.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
