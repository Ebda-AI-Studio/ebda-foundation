# AI review gate

Every PR except an all-safe one (markdown, `docs/`, newly added test files; a modified or deleted existing test IS reviewed) is reviewed by `claude -p` in CI. The gate runs from the BASE branch (`pull_request_target`; the PR is only fetched as data), so a PR cannot edit it to pass; edits under `.github/` are always reviewed. No criticals: label `ai-review-passed`. Criticals or any infra problem: the check fails. The drain loop merges a `risky-path` PR only with `ai-review-passed`.

Files: `pass-marker.mjs` (keeps `ai-review-passed` tied to the reviewed diff via a patch-id marker comment: a clean merge of main keeps the label, any change to the PR's own diff strips it), `risky-paths.mjs` (path classifier), `prompt.md` (rules, including the slop section), `review.mjs` (parses the model output, posts findings, gates). Workflow: `.github/workflows/ai-review.yml` (reusable, `workflow_call` only). Rulings AIR-1..3 in `docs/RULINGS.md`.

## Adopt in a product repo
1. Copy `risky-paths.mjs`, `pass-marker.mjs`, `prompt.md`, `review.mjs` to `.github/ai-review/`.
2. Copy the workflow to the product repo with `on:` replaced by `pull_request_target: types: [opened, synchronize, reopened, ready_for_review, labeled]`. Everything under `jobs:` stays identical.
3. Secret `CLAUDE_CODE_OAUTH_TOKEN` (run `claude setup-token` as the Claude account that pays for review; `gh secret set CLAUDE_CODE_OAUTH_TOKEN -R <owner>/<repo>`, or once for the org). Without it every risky PR fails with an error that says so.
4. Optional repo variable `AI_REVIEW_MODEL`.

Fork PRs: never reviewed with secrets, never skipped: the check is red until a maintainer adds the label `ai-review-passed` (Ruling AIR-5). A diff of 400 KB or more FAILS (no partial review): get human/controller review, then add the label `ai-review-passed` by hand, or split the PR.
