# No continuity plan for the one provider everything runs on

Pack: business, cloudflare | Probe type: J | Source: Ebda AI Studio audit 2026-10-26 BIZ-28, BIZ-29

## Claim
When one provider hosts everything, a continuity note (second owner, break-glass, export path) is required.

## Scenario
Cloudflare ran everything for Ebda and the account sat on one person's personal login; one founder, one agent fleet.

## Source candidate
- (medium) Provider is documented but no continuity/second-owner/break-glass is mentioned.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading. This lens is judge-graded: the probe only locates the candidate, the verdict needs the surrounding product behaviour.

## Fix template
Name a second owner, store break-glass access offline, document the export path.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
