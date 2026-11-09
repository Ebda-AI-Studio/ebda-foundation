# Server fetches a request-supplied URL without a host guard

Pack: security | Probe type: S | Source: Ebda AI Studio audit 2026-10-26 SEC-6

## Claim
A server-side fetch of a URL taken from the request must block private ranges and cap size and time.

## Scenario
Ebda's OG image route fetched a caller-chosen URL, giving blind SSRF into the internal network.

## Source candidate
- (high) fetch() of a request-supplied URL with no visible host/private-range guard.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Resolve the host, deny private/link-local ranges, allowlist schemes, cap bytes and time.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
