# Custom hostnames used with no Cloudflare-for-SaaS setup

Pack: cloudflare | Probe type: S+J | Source: Ebda AI Studio audit 2026-10-26 OPS-18

## Claim
Merchant custom domains need the Cloudflare-for-SaaS pieces: a fallback origin, custom hostname API access and SSL settings.

## Scenario
Ebda merchant custom domains could not work in production: the Cloudflare-for-SaaS settings were unset.

## Source candidate
- (high) Custom-domain code exists but no fallback-origin / SSL-for-SaaS configuration is referenced.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading. This lens is judge-graded: the probe only locates the candidate, the verdict needs the surrounding product behaviour.

## Fix template
Set the fallback origin and SSL for SaaS on the zone and verify with a test hostname.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
