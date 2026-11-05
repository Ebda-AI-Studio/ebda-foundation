# AI moderation that approves when the moderator errors

Pack: ai-safety, security | Probe type: S | Source: Ebda AI Studio audit 2026-10-26 SEC-2

## Claim
If the model call, parse or timeout fails, the content must go to a review queue, never to published.

## Scenario
Ebda AI review moderation auto-published when the moderation call failed, and reviews could carry instructions aimed at the moderator.

## Source candidate
- (critical) catch branch of a moderation call sets approved/published.
- (critical) catch block of a moderation call approves or publishes the content.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Fail closed: on any error set status pending_review and alert; approve only on an explicit, schema-valid verdict.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
