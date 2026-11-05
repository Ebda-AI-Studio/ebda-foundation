# Redirect loop on a policy or deep URL

Pack: seo, reliability | Probe type: H | Source: feedback-a-control-that-cannot-generalise (2026-09, 50-hop loop on two live policy pages)

## Claim
Every rewrite must be checked in both directions; follow every hop.

## Scenario
Generalising 'extensionless paths 404' shipped a 50-hop redirect loop onto two live policy pages.

## Source candidate
- (high) Snapshot shows a redirect loop.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Probe the rewrite's reverse direction and follow all hops in CI.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
