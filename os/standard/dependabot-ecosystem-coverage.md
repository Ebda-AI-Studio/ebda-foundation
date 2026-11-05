# Dependabot covers only GitHub Actions

Pack: cicd, security | Probe type: S | Source: Ebda AI Studio audit 2026-10-26 OPS-22

## Claim
Automated update PRs must cover the package ecosystems the repo ships, not only workflow actions.

## Scenario
Ebda's Dependabot config covered github-actions only, while production ran old and unmaintained npm dependencies.

## Source candidate
- (medium) dependabot.yml lists github-actions but no application package ecosystem.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Add npm (and any other ecosystem in use) with a weekly schedule and grouped updates.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
