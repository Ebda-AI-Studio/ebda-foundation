# No refund or cancellation policy for the product's own subscriptions

Pack: docs, business | Probe type: S | Source: Ebda AI Studio audit 2026-10-26 BIZ-25

## Claim
A product that bills must publish a refund and cancellation policy before it charges.

## Scenario
Ebda had no published refund and cancellation policy for its own subscriptions and wallet, and BRAND.legalUrls.refunds returned 404.

## Source candidate
- (high) Billing/checkout text exists but no refund or cancellation policy is published.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Publish /refunds linked from checkout and the footer.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
