# AI review gate

A PR touching money, auth, data or migrations is reviewed by `claude -p` in CI. No criticals: label `ai-review-passed`. Criticals or any infra problem: the check fails. The drain loop merges a `risky-path` PR only with `ai-review-passed`.

Files: `risky-paths.mjs` (path classifier), `prompt.md` (rules, including the slop section), `review.mjs` (parses the model output, posts findings, gates). Workflow: `.github/workflows/ai-review.yml` (reusable, `workflow_call` only). Rulings AIR-1..3 in `docs/RULINGS.md`.

## Adopt in a product repo
1. Copy `risky-paths.mjs`, `prompt.md`, `review.mjs` to `.github/ai-review/`.
2. Copy the workflow to the product repo with `on:` replaced by `pull_request: types: [opened, synchronize, reopened, ready_for_review]`. Everything under `jobs:` stays identical.
3. Secret `CLAUDE_CODE_OAUTH_TOKEN` (run `claude setup-token` as the Claude account that pays for review; `gh secret set CLAUDE_CODE_OAUTH_TOKEN -R <owner>/<repo>`, or once for the org). Without it every risky PR fails with an error that says so.
4. Optional repo variable `AI_REVIEW_MODEL`.

Not covered: fork PRs (no secrets, the fork guard skips them), a diff over 400 KB (the reviewer sees the first 400 KB; the job warns).
