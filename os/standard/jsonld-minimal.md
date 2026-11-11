# Structured data missing key fields or marking plans PreOrder

Pack: seo | Probe type: S | Source: Ebda AI Studio audit 2026-10-26 SEO-8, SEO-11, BIZ-31

## Claim
JSON-LD must carry the fields rich results and answer engines use (offers, availability, sameAs), and must not mark live products PreOrder.

## Scenario
Ebda's storefront Product JSON-LD was minimal, entity markup had gaps, and the home page marked the three plans as PreOrder.

## Source candidate
- (medium) JSON-LD present but none of offers/aggregateRating/sameAs/availability appears.
- (medium) Availability is PreOrder in structured data.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Complete Product/Organization schema (offers.price, availability InStock, sameAs) and test it.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
