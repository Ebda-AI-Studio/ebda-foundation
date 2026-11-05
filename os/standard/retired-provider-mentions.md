# Docs or config still name a retired provider

Pack: docs, cicd | Probe type: S | Source: Ebda AI Studio audit 2026-10-26 DOC-15, OPS-15

## Claim
Providers the product has left must not appear in docs, runbooks or workflows; they send the next operator to the wrong console.

## Scenario
Ebda's operational docs and repo leftovers still described Railway, Redis and an old Neon project after the Cloudflare move; inherited ledger docs carried retired providers and foreign-law wording.

## Source candidate
- (low) A retired provider named in .fleet-retired-providers.txt is still mentioned.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Keep the denylist in .fleet-retired-providers.txt and fail CI on a hit.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
