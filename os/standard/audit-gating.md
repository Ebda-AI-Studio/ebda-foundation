# Audit Gating — the OS's deterministic second layer (per-PR + nightly + on-demand)

**Ahmad's mandate (2026-06-10):** "Make sure the blast-radius AND the deep unified
audit run each time I push, so nothing breaks from the other features or core. My
PC runs all the CI. The CI must be very mature so it can be the second layer of the
OS itself."

The OS's FIRST layer is my reasoning (the audit fleet I dispatch in-session). The
SECOND layer is **CI** — deterministic, always-on, catches what the first layer
misses. Both layers must agree before code reaches a merchant.

## The tiered model (the decision)

Running the full 16-dimension Opus fleet on every push is slow + token-heavy and
would burn Opus on a typo PR. So coverage is tiered by cost vs. blast radius:

| Tier | Trigger | What runs | Cost |
|------|---------|-----------|------|
| **Per-PR** | every `pull_request → main` | blast-radius (always) + a **blast-radius-SCOPED audit** — only the dimensions the change actually touches | cheap, fast |
| **Nightly** | schedule (03:00) | the **full 16-dimension unified audit** across the whole repo | heavy, off-peak |
| **On-demand** | `workflow_dispatch` / an audit run | the full fleet, any time | as needed |

**Per-PR scoping = blast-radius drives the audit.** The changed files + their
transitive dependents (from the graphify graph) determine BOTH the file set AND the
dimension set:

| Changed/dependent path shape | Dimensions run on the PR |
|---|---|
| payment / order / checkout / money | money, rls, contract-drift, reliability, security |
| `apps/api/**/routes`, middleware, services | security, contract-drift, rls, scaling |
| `packages/database`, prisma, migrations | rls, contract-drift, scaling, data→UI |
| `packages/shared` (kernel) | contract-drift + ALL dependent-app dims (max blast radius) |
| `apps/web`, `apps/admin` components | ui/ux, a11y, contract-drift |
| webhook / worker / cron / inngest | rls (async-writer coverage), reliability, idempotency |
| `.github/`, ops, scripts, docs-only | docs-parity (light); skip heavy dims |

## The gate (the decision)

- **Confirmed P0/P1 → BLOCKS the merge** (check fails). P0/P1 = broken core, security,
  money, RLS/tenancy, data-loss. A finding must be *adversarially verified* (real, with
  file:line evidence) before it blocks — no false-positive gridlock.
- **P2/P3 → never block an unrelated PR, but are NEVER dropped.** Each is auto-filed as a
  tracked **must-fix follow-up** (GitHub issue, labelled `audit-followup` + severity, linked
  to the PR). "Fix everything always" holds: nothing is silently ignored; it's tracked and
  closed. (Ahmad: "1 but must fix everything always.")
- **blast-radius itself is informational** — it annotates the step summary + a PR comment
  with the dependents to review; it never fails the build.

## PC runs all CI (already mature on a previous storefront product — replicate everywhere)

`runs-on` routes via `${{ (inputs.force_cloud || vars.USE_SELF_HOSTED != 'true') &&
'ubuntu-latest' || fromJSON('["self-hosted","linux","wsl2"]') }}`. With
`USE_SELF_HOSTED=true` (repo variable), **all WORK jobs run on the PC**; only the
**safety-net jobs stay hardcoded to `ubuntu-latest`** — by design, so they survive a
PC outage:

- `notify-failure` (fail-open Telegram alert)
- `runner-health-check` (can't run on the thing it's checking)
- `cloud-rescue` (the failover when self-hosted is down)

The `ci-runner-guard` (launchd, every 30 min) auto-fails-over to self-hosted when cloud
minutes are exhausted. Per-repo checklist: (1) `USE_SELF_HOSTED=true` set; (2) every
work job uses the routing expression; (3) the 3 safety-net jobs stay on cloud; (4)
runners auto-start + auto-restart as a service; (5) serialize merges when ≤2 runners
(concurrent PRs cause job *cancellations* that surface as false "fail" — trust the
final per-job conclusion + `mergeStateStatus=CLEAN`).

## Deterministic encodings (CI mirrors the audit's reasoning)

Each audit bug-CLASS we discover gets a cheap deterministic CI gate so the second
layer catches the regression even without the Opus pass:

- **RLS async-writer coverage (audit F4):** grep gate — any tenant-table write outside
  `runInTenantContext` / `withRlsBypass` fails CI. (`ops/rls-writer-gate.sh` — **NOT YET BUILT**; a previous storefront product's RLS proof job covers part of this today)
- **Contract drift:** the existing tsc + Zod-at-every-edge + integration tests.
- **Sentry-noise class (audit F1):** `sentry.service.test.ts` pins the 4xx-not-captured gate.
- New class → new gate, appended here + to memory (the self-improving loop, step 10).

## Files

- `ops/blast-radius.sh` — transitive-dependent surfacing (graphify graph). Per-PR.
- `ops/scoped-audit.sh` — **NOT YET BUILT as a shared ops script** (never existed in git; the
  working implementation is a previous storefront product's `.github/workflows/scoped-audit.yml` "Blast-radius scoped
  audit (Opus)" job). Intended shape: blast-radius-scoped Opus audit via `claude -p
  --output-format json`; findings JSON; exit 1 on confirmed P0/P1; P2/P3 for issue-filing.
- `ops/unified-audit-full.sh` — **NOT YET BUILT** (never existed in git); the full 16-dim
  fleet runs today interactively, not as a scheduled script.
- `.github/workflows/blast-radius.yml` — per-PR, informational.
- `.github/workflows/scoped-audit.yml` — per-PR, blocking on P0/P1 + files P2/P3 issues.
- `.github/workflows/unified-audit-nightly.yml` — schedule + `workflow_dispatch`.

**Source of truth:** this file + `standard/unified-audit.md` (the 16 dimensions) +
`feedback-os-self-improving-audit-loop` (the loop this gates). Every new bug-class
APPENDS a deterministic gate here.
