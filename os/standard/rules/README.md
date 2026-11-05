# rules/ — Per-Language Rule Packs

This directory closes an ECC (external reference framework) gap: ECC ships language/framework-specific
rule packs under `rules/{python,react,rust,...}`, keyed by file type so the right rules auto-load for
the file being touched. The parent `standard/` directory (`rls.md`, `scaling.md`, `deps.md`, `testing.md`,
`money.md`, `security.md`, `cicd.md`, `frontend-quality.md`, `observability.md`, `dr.md`, `environments.md`,
`docs-parity.md`, `auth.md`, `feature-flags.md`, `event-log.md`, `cache-ratelimit.md`, `audit-gating.md`,
`unified-audit.md`, `worktree-lifecycle.md`, `common-test-files.md`) holds Ahmad's **cross-cutting**
rubrics — the "what solid looks like" criteria that apply to a whole repo or feature regardless of which
language wrote it. This directory holds the complement: rules specific to ONE language or framework in
Ahmad's actual stack, auto-relevant the moment a matching file is opened.

## Files

| File | Auto-relevant for |
|---|---|
| `typescript.md` | Any `.ts`/`.tsx` — API-edge validation, mock-factory drift, dependency-override pinning, TS/monorepo type coexistence |
| `react-nextjs.md` | Any `.tsx`/`.jsx`, Next.js App Router routes — i18n/RTL, Tailwind JIT/v4 traps, force-dynamic + migration ordering |
| `node-express.md` | Express route handlers, middleware, webhooks, workers — pool starvation, CSRF, Jest-hang root causes |
| `prisma-postgres.md` | `schema.prisma`, Prisma client usage, raw SQL migrations, RLS policies — Neon pooling, enum migrations, transaction timeouts |
| `bash-ops.md` | `.sh` scripts, CI workflow files, launchd/cron, ops tooling — shell gotchas, CI hang debugging, blast-radius sweeps |

## Why these five

They map to Ahmad's actual production stack across FWB, WBS, Salam ERP, and every new Force AI project:
Next.js/React on the frontend, Node/Express APIs, Prisma+Postgres(Neon) for data, TypeScript everywhere,
and Bash for ops/CI/automation. This is not a generic "cover every language" set — it's mined from real
incidents (see each file's `sources:` frontmatter line) rather than invented best-practices, so every
"Must Always"/"Must Never" traces back to a dated, verified production trap.

## Structure

Each rule pack follows the same shape, mirroring ECC's `rules/` convention and Ahmad's own memory-file
style (`feedback-*.md` in `~/.claude/projects/-Users-ahmadsharaf/memory/`):

- **Must Always** — non-negotiable practices, each with the "why" (the failure mode it prevents)
- **Must Never** — anti-patterns that have caused a real incident, not theoretical risks
- **Patterns** — copy-pasteable code shapes / diagnostic recipes that implement the rules correctly
- **Traps** — surprising failure signatures (a green build that's actually broken, a silent no-op, a
  misleading error message) — the "how you'd misdiagnose this" knowledge that saves re-debugging time
  already spent once

## How this relates to the cross-cutting `standard/` docs

A single feature touches BOTH layers. Example: adding a new Prisma-backed API endpoint on a Next.js
admin page should pull `../rls.md` + `../scaling.md` + `../money.md` (cross-cutting: is this endpoint
tenant-isolated, paginated, transaction-safe) AND `prisma-postgres.md` + `node-express.md` +
`typescript.md` (language-specific: is the enum migration hand-written, is the Zod schema in lockstep,
is the transaction timeout set). Each rule-pack file cross-links back to the cross-cutting docs it
composes with in a `Cross-links:` line at the bottom.

## Maintenance

When a new dated lesson lands in `~/.claude/projects/-Users-ahmadsharaf/memory/feedback-*.md` that is
language/framework-specific (not cross-cutting), fold it into the matching rule pack here in the same
pass — per the standing "one rolled-up file per theme" memory-rollup rule, not as a new file. If a
lesson doesn't fit any of the five existing packs and recurs across ≥2 projects, that's the bar for
adding a sixth pack (e.g. `python.md`, `railway-deploy.md`) rather than bloating an existing one.
