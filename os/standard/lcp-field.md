# Largest Contentful Paint above 2.5 s

Pack: perf | Probe type: H | Source: Ebda AI Studio audit 2026-10-26 SEO-1, SEO-6

## Claim
Product page LCP must be under 2.5 s on a slow-4G profile.

## Scenario
Ebda storefront product page LCP was 6.7 s on slow 4G.

## Source candidate
- (medium) Lighthouse snapshot LCP is 2.5 s or more.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Preload and size the hero image, cut main-thread cost, cache HTML.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
