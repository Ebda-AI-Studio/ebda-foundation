# Cloudflare config tied to a personal mailbox

Pack: cloudflare, business | Probe type: J | Source: Ebda AI Studio audit 2026-10-26 BIZ-28, BIZ-29

## Claim
Production infrastructure on a personal login is a single point of failure for the company.

## Scenario
Ebda ran everything on Cloudflare, on Ahmad's personal account (vendor concentration and bus factor).

## Source candidate
- (medium) Cloudflare config or docs reference a personal mailbox.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading. This lens is judge-graded: the probe only locates the candidate, the verdict needs the surrounding product behaviour.

## Fix template
Move to an organisation account with two owners and a break-glass procedure.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
