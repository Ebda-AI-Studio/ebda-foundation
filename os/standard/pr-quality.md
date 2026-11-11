# pr-quality - no AI slop in a PR

A PR is evidence, not a description. Each rule below either has a mechanical guard (`ci/pr-quality/`, workflow `.github/workflows/pr-quality.yml`, ESLint in the product) or is checked by the CI reviewer (`ci/ai-review/prompt.md`, "SLOP" section). A rule with neither is a preference, not a gate.

| Rule | Enforced by |
|---|---|
| Every bug fix has a test that FAILS on the old code; the PR body records the mutation check (what was reverted, the failing output) | `pr-body-check.mjs` (fix PR: `## Mutation check` + a test file in the diff); reviewer ("tests that cannot fail") |
| No speculative abstraction, no unused export, no dead code | `slop-guard.mjs` `unused-export`; reviewer ("over-engineering", "dead code") |
| One source per helper (slugify, pricing, money format): no duplicated function bodies | `slop-guard.mjs` `duplicate-helper`; reviewer ("copy-paste") |
| No `any` in app code | ESLint `@typescript-eslint/no-explicit-any` + `slop-guard.mjs` `no-any` |
| No `console.log` in app code | ESLint `no-console` + `slop-guard.mjs` `no-console` |
| No TODO/FIXME without an issue link (`#123` or an issues URL) | ESLint `no-warning-comments` (issue-link exception) + `slop-guard.mjs` `todo-no-issue` |
| No "best effort / should work / probably" claims; PR bodies carry `## Verified`, `## Not verified`, `## Cost-if-wrong` | `pr-body-check.mjs` |
| No needless comments, no fake tests that assert mocks, no tests that cannot fail | reviewer only (not mechanical) |
| Arabic copy is Egyptian, no emoji, no MSA mixing; public copy is present tense | `slop-guard.mjs` `emoji-copy` on locale files; Egyptian-vs-MSA and tense are reviewer/human only |

## Baselines only shrink
Adopting a guard in a repo with existing violations records them once (`--update --init`). After that a PR fails when it ADDS a violation and also when a fixed violation is still listed (run `--update`, which refuses to add anything). Violation ids are `rule|file|content-hash`, never line numbers, so moving code does not churn the baseline. An intentional exception is written inline as `pq-allow(<rule>): <reason>` (a reason is required) and is visible in review.

## Learning loop
An issue labelled `review-finding` closed by a PR must be closed by a fix that (a) adds the test and (b) points at the foundation rule or guard that would have caught it. The PR body carries two checked lines the `PR body sections` job verifies:

    - [x] Test: <path of a test file in this diff>
    - [x] Foundation: <rule/guard path, foundation PR url, or ruling id>

Linking is by `Fixes|Closes|Resolves #N`. If GitHub cannot be read to look up the issue's labels, the check fails (unknown is not pass).

Sources: gate-integrity.md, coding-hygiene.md. Rulings PRQ-1 in `docs/RULINGS.md`.
