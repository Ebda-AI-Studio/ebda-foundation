# Deploy workflow has no failure notification

Pack: observability, cicd | Probe type: S | Source: Ebda AI Studio audit 2026-10-26 OPS-5, BIZ-22

## Claim
A failed deploy or production error must reach a human by a channel that is watched while the owner sleeps.

## Scenario
No alert reached a human when Ebda production or a deploy broke, and production alerts went to one personal email.

## Source candidate
- (high) Deploy workflow exists but nothing notifies on failure.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Add a notify-failure job (chat/pager) to deploy workflows, with a second recipient.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
