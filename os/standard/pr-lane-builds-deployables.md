# PR workflow does not build every app the deploy workflow builds

Pack: cicd, security | Probe type: S | Source: Ebda master catalogue 2026-10-26 sec.7 L01

## Claim
A security fix is not done until the pipeline that ships it is proven to build and deploy that app; the PR lane must build every deployable the deploy lane builds.

## Scenario
Ebda's critical-RCE Next.js bump could not be proven: the storefront auto-deploy failed on main while the PR lane never built that app (M-001, M-004, M-016).

## Source candidate
- (high) Deploy workflow builds an app that no pull_request workflow builds.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
List deployables in one place and make PR CI build each of them (path-filtered).

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
