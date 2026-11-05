# deps — Dependency Discipline Rubric

tags: [BOTH]
sources: PLAYBOOK §6 (audit split), §7 (lockfile regen), §9 (dependency discipline), CLAUDE.md (Rule 1 — dependency discipline), reference-iceberg-audit.md (rule 1 source), reference-force-ai-production-grade-standard.md (layer 5: security / supply-chain)

## What "solid" looks like
Every added dependency passes a 5-point gate before commit: it exists in the registry, was released within the last 12 months, carries a compatible license, and keeps the dep tree sane; `npm audit` reports 0/0/0/0 at every severity; the CI audit gate enforces zero-tolerance on prod deps; transitive vulns are fixed by overriding the leaf (never by downgrading a framework), and in a monorepo overrides use the nested form.

## Criteria
| # | Criterion | Solid (grade 2) | Gap detection | Severity |
|---|---|---|---|---|
| 1 | Registry-exists check | Every dependency resolves to a real published package (no slop-squatted / hallucinated names) | `npm ls --all` (or `npm ci`) resolves with no `missing`/`UNMET DEPENDENCY` / 404 lines; cross-check each `package.json` dep against `npm view <name> version` | Critical |
| 2 | Recency (<12mo release) | Each direct dep's latest release is within the last 12 months (no abandoned packages) | `npm outdated --long`; for each direct dep `npm view <name> time.modified` and flag any > 12 months old | Medium |
| 3 | License compatibility | Every dependency's license is compatible (no GPL/AGPL copyleft pulled into a proprietary app) | grep dep `license` fields / run a license report; flag any `GPL`/`AGPL`/`SSPL`/`unknown`/`UNLICENSED` in the tree | High |
| 4 | Dep-tree sanity | No duplicate/conflicting major versions or surprise transitive bloat | `npm ls --all` shows no `invalid`/`deduped`-conflict warnings; `npm ls <framework>` returns a single major version | Medium |
| 5 | npm audit 0/0/0/0 | `npm audit` reports zero vulns at every severity (low/moderate/high/critical) | `npm audit --json \| jq '.metadata.vulnerabilities'` — every count must be 0 | Critical |
| 6 | CI audit gate (prod zero-tolerance) | CI runs `npm audit --audit-level=low --omit=dev` on prod deps (dev deps gated at high for unfixable tooling vulns) | grep `.github/workflows/*.yml` for `npm audit`; confirm `--audit-level=low` + `--omit=dev` on the prod gate, not `--audit-level=critical` | High |
| 7 | Override-the-leaf (no framework downgrade) | Transitive vulns fixed by pinning the vulnerable leaf in `overrides`; framework-downgrade `fixAvailable` never accepted | grep `package.json` `overrides`; confirm `npm audit fix --force` was NOT run to downgrade a major framework version | High |
| 8 | Monorepo overrides use nested form | In a workspace, overrides are expressed in the nested per-package form (not a flat top-level pin that misses the workspace) | grep root `package.json` `overrides`; in a monorepo confirm the nested `"pkg": { "dep": "ver" }` shape | Medium |
| 9 | Audit-fix uses the lock's generator npm + all workspaces | `npm audit fix --package-lock-only` run with the npm matching the lock's `lockfileVersion` (a mismatched npm wholesale-rewrites the lock); in a monorepo fix EVERY workspace lockfile; a vuln whose only fix is `--force` is closed by a deliberate PARENT upgrade (verify the consumer API is stable), never `--force`-blind | review audit-fix diff size (huge churn = wrong npm); confirm every workspace lock clean post-fix | High |

| 10 | One package manager per repo (no cross-PM pollution) | The repo's declared PM (npm workspaces here) is the ONLY one ever run; never `pnpm`/`yarn` in an npm-workspace repo — it writes a parallel store + hoists DUPLICATE/dual-version deps (e.g. two React copies) that break the build at runtime. Subagents + CI inherit the repo's PM. | look for a stray `pnpm-lock.yaml`/`.pnpm`/`yarn.lock` in an npm repo; confirm one lockfile type; check `node_modules` has no duplicate framework copies (`npm ls react`) | High |
| 11 | Cross-version framework types coexist in a mixed monorepo | When one workspace pins React 18 (Expo) and another React 19 (Next) in a pnpm/monorepo, `@types/react` is pinned per-workspace (or via nested overrides) so `tsc` doesn't collapse them to one incompatible global type | in a mixed-React monorepo, confirm per-workspace `@types/react` resolution (no single hoisted mismatched version) | Medium |

_Sources: `feedback-subagent-pnpm-pollution-dual-react` (crit 10), `feedback-pnpm-react18-19-types-coexistence` (crit 11)._

## Evidence (filled during audit, per repo)
- FWB: …
- WBS: …
