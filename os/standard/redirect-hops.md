# Deep link needs more than one redirect

Pack: seo, perf | Probe type: H | Source: Ebda AI Studio audit 2026-10-26 SEO-12

## Claim
http deep links should reach the final HTTPS URL in one hop.

## Scenario
Ebda deep http links took 2 hops.

## Source candidate
- (low) Snapshot shows two or more redirect hops.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Redirect http to final https in a single 301 at the edge.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
