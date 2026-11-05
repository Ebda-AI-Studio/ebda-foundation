# Locale held in a cookie only: no URL, no hreflang

Pack: seo | Probe type: S | Source: Ebda AI Studio audit 2026-10-26 SEO-9

## Claim
A language that exists only behind a cookie cannot be indexed; each locale needs its own URL and hreflang alternates.

## Scenario
Ebda storefront English was cookie-only: no URL, no hreflang, not indexable.

## Source candidate
- (medium) Locale is selected from a cookie but no hreflang/alternates are emitted.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Serve /en and /ar paths and emit alternates.languages / hreflang.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
