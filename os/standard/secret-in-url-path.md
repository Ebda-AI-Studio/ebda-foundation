# Webhook secret carried in the URL path

Pack: security | Probe type: S | Source: Ebda AI Studio audit 2026-10-26 SEC-8

## Claim
A shared secret must not travel in a URL path or query string, because platforms and proxies log URLs.

## Scenario
Ebda's Bosta webhook secret was a path segment, so it landed in request logs of the Worker platform.

## Source candidate
- (high) Route path embeds a secret/token parameter, which is logged with the URL.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Authenticate with a header signature or a hashed token compared in constant time; strip query and path secrets from logs.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
