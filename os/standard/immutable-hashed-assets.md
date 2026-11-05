# Hashed assets served with max-age=0

Pack: perf | Probe type: H | Source: Ebda AI Studio audit 2026-10-26 SEO-4

## Claim
Content-hashed JS/CSS/images can be cached forever; max-age=0 forces a revalidation round trip on every page view.

## Scenario
Ebda served hashed JS/CSS/images and og.png with max-age=0, must-revalidate.

## Source candidate
- (medium) Hashed asset response is not cacheable long-term.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
cache-control: public, max-age=31536000, immutable on hashed paths.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
