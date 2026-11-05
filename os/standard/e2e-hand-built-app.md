# 'E2E' test that builds its own mini-app instead of using the real entry point

Pack: cicd | Probe type: S | Source: Ebda master catalogue 2026-10-26 sec.7 L42

## Claim
End-to-end means the real app entry point and a browser journey; a hand-built mini-app is an API test.

## Scenario
Ebda's 'E2E' tier was supertest on a hand-built Express app with guest checkout skipped (M-038).

## Source candidate
- (medium) e2e/integration test constructs its own express()/Hono app.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Import the real app factory and drive a browser (Playwright) through signup and checkout.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
