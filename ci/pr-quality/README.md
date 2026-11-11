# PR quality guards

`pr-body-check.mjs` (PR body sections, fix rule, review-finding learning loop) and `slop-guard.mjs` (six baselined rules). Standard: `os/standard/pr-quality.md`. Workflow: `.github/workflows/pr-quality.yml` (reusable; copy with `on: pull_request` types `[opened, synchronize, reopened, edited, ready_for_review]` until Actions access on this repo is `organization`).

Adopt in a product repo:
1. Copy both scripts to `.github/pr-quality/`; add `.github/PULL_REQUEST_TEMPLATE.md` with the three sections.
2. `.pr-quality.json`: `{ "roots": ["apps","packages"], "locales": ["<dir of locale json>"], "baseline": ".pr-quality-baseline.json" }`.
3. `node .github/pr-quality/slop-guard.mjs --update --init` once, review the baseline, commit it.
4. Add the ESLint rules named in the standard (warnings that are errors in CI).

`node slop-guard.mjs --list` prints every current violation.
