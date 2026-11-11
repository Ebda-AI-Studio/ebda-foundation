# Third-party script tag without Subresource Integrity

Pack: security, frontend | Probe type: S | Source: Builder-reality reel pack (reel-lenses-2026-09) + playbook sec 14, L1

## Claim
A script loaded from another origin runs with the page's privileges; pin it with integrity + crossorigin or self-host it.

## Scenario
A chat widget script tag can read the page, the DOM and any token the page can reach; if its host is compromised so is the site.

## Source candidate
- (medium) <script src=https://...> has no integrity attribute.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Add integrity and crossorigin attributes, self-host, or load it in a sandboxed iframe.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
