# supply-chain — Third-Party Code & Action Provenance Rubric

tags: [BOTH]
sources: reference-harness-extraction-2026-09.md, feedback-mutable-action-tags-are-a-supply-chain-hole.md, ECC `.github/workflows/ci.yml:35` (SHA-pinning practice), deepseek-harness `vendor/README.md` (vendored-provenance contract)

## What "solid" looks like
Nothing third-party runs in our CI or ships in our products at a reference someone else can silently repoint. Every `uses:` in every workflow is a 40-hex commit SHA with a trailing version comment. Our own reusable workflows are pinned by consumers too, so a foundation push cannot change consumer CI without a reviewed bump. Dependency checks verify *provenance* (`npm audit signatures`), not just known-vulnerability counts. Any source-vendored code carries a manifest naming its upstream repo, version and exact commit, plus an exhaustive log of every local divergence.

## Why this exists
Measured across `~/Desktop/projects` on 2026-09-04: **223 of 229 GitHub Action references in 20 repos were mutable tags** — 116× `actions/checkout@v4`, 73× `actions/setup-node@v4`. One reference (`trufflesecurity/trufflehog@main`) floated on a *branch*. Only 13 distinct refs existed estate-wide, so the entire exposure was 11 SHA lookups. A tag is a pointer the action's owner controls; when it is repointed, their code executes in our runner with our secrets, produces no diff on our side, and passes review because there is nothing to review. This is the class that hit `tj-actions/changed-files`.

## Criteria
| # | Criterion | Solid (grade 2) | Gap detection | Severity |
|---|---|---|---|---|
| 1 | Every action ref is a commit SHA | Every `uses:` is `owner/repo@<40-hex> # <version>`; the comment records which version the SHA was, so a human can read the intent | `ops/pin-actions.sh --check --repo <repo>` — exit 1 lists every mutable ref as `file:line` | Critical |
| 2 | No branch refs, ever | No `@main`, `@master`, `@develop`. A branch has no version identity at all: pinning its head at least records *when*, but the ref itself must not survive | grep workflows for `uses:.*@(main\|master\|develop)` | Critical |
| 3 | Our own reusable workflows are pinned by consumers | A consumer's `uses: Ebda-AI-Studio/ebda-foundation/.github/workflows/reusable-ci.yml@<sha>` — not `@master`. Otherwise any foundation merge changes consumer CI instantly, unreviewed, and a bad merge breaks every consumer at once | grep consumer workflows for `ebda-foundation/.github/workflows/.*@master` | High |
| 4 | Registry provenance is verified, not just vuln-counted | CI runs `npm audit signatures` alongside `npm audit`. The former proves the package was published by whom it claims; the latter only counts known CVEs. A supply-chain compromise is signature-visible before it is CVE-visible | grep CI for `npm audit signatures` | High |
| 5 | No version drift for the same action | The same action appears at one version across the estate. Two versions means one repo is silently on older behaviour and nobody chose that | `grep -rhoE "uses: [^@]+@[^ ]+" */.github/workflows \| sort -u`, flag any action name appearing twice | Medium |
| 6 | Pinning is gated, not just done | A CI job runs the `--check` mode. A one-time sweep decays; without a gate the next new workflow reintroduces a mutable tag and nobody notices | grep `ci.yml` for a job invoking `pin-actions.sh --check` | High |
| 7 | Vendored third-party source carries provenance | Any source-copied dependency has a manifest row per package: directory, our name, upstream name, version, upstream repo, **exact commit SHA** — plus an exhaustive local-modification log with a rationale per divergence, and an explicit "intentionally not vendored" list | file-exists `VENDOR-PROVENANCE.md`; assert every manifest row has a 40-hex SHA | High |
| 8 | An upstream's license is read from the API, not the README | A README badge is decoration. `gh api repos/<o>/<n> --jq .license` is the fact. Auto-Company displays an MIT badge and resolves to `null` — all rights reserved | for each vendored/ported upstream, record the API-resolved SPDX id in the provenance file | High |

## Tightening this gate on shared workflows
Adding the `--check` step to `reusable-ci.yml` makes it a **breaking change for every consumer at once** — each consumer repo still carrying a mutable ref goes red on its next run. Pin the consumers first, then tighten the shared workflow. Removing an exemption is a change to everyone who relied on it, and the sweep comes before the gate.

## Special cases and how to handle them
- **A branch ref (`@main`)**: resolve to today's SHA and add the pin date in the comment, since there is no version to record. Open a follow-up to move to a tagged release.
- **The same action at two versions**: pin each to its own SHA now. Do **not** upgrade the older one in the same commit — that is a behaviour change riding a mechanical one, and it will be blamed on the pinning if it breaks.
- **A possibly-archived action**: check `gh api repos/<o>/<n> --jq '{archived,pushed_at}'` and record it. Pin it anyway — pinning an archived action is strictly safer than floating on it — and open a migration follow-up.

## Evidence (filled during audit, per repo)
- ebda-foundation: 21 refs pinned 2026-09-04; `--check` gate live in `ci.yml`.
- Remaining estate: 202 refs across 19 repos, sweep pending.
