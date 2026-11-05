# The Dreaming Cycle — the OS's daily autonomous improvement loop

**Ahmad, 2026-06-10/11.** Every morning the OS LEARNs what changed in the world,
SCANs all Force repos, ACTs on what it finds (auto-fixing the safe tier, proposing
the rest), and writes back what it learned. It is the proactive half of the Whisky
AI OS (the reactive half is alert-triage + the synthetic monitors).

## The four phases (orchestrated by `ops/dream.sh`)
1. **LEARN** — `ops/dream-research.sh`: batch-query osv.dev with every repo's actual
   lockfile → "new-to-us CVEs"; note ecosystem-research cache staleness → `world-digest.json`.
2. **SCAN** — `ops/dream-scan.sh`: DAILY = deps + lockfile-drift + new-CVE-hits.
   WEEKLY (`--deep`, auto on Sunday) = dead-code (graphify), doc-drift (docs-scan),
   perf/code-smell heuristics, code-health, and the **encoded-detector fleet**
   (`ops/detectors/*.json` via `ops/lib/detector-run.py`: RLS-write-policy gap,
   raw-SQL injection, missing-Zod on API routes, CSV formula injection, storeUrl
   double-slash, and — added 2026-07-12, Lens P/perf-vibecode —
   `api-response-compression-missing.json`, an Express entrypoint with no
   `compression()` middleware; and — added 2026-07-13, cache-stampede lens —
   `cache-wrap-missing-single-flight.json`, a read-through cache helper
   (`getCached(`/`cacheService.wrap(`/`cache.wrap(`) with no in-flight promise
   guard, so concurrent misses on the same key each trigger their own rebuild)
   → normalized `dream-findings.json`.
3. **ACT** — `ops/dream-act.sh`: dedupe vs the ledger, classify each finding into a tier,
   dispatch (Tier A → `dream-fix.sh`, capped at `DREAM_MAX_FIXES`=3; Tier B → `dream-proposal`
   issue; Tier C → urgent Telegram).
3.5. **STANDARD-DRIFT** — `ops/dream-standard-drift.sh`: the **memory→standard authoring
   bridge** (propose-only). The memory pipeline keeps the foundation's *mechanical*
   artifacts synced (`sync-foundation.sh`), but turning a cross-cutting memory LESSON
   into a `standard/` rubric needs reasoning — this lens does it autonomously and
   conservatively. DETECT (deterministic): cross-cutting lessons (marked "indexed in
   global MEMORY.md") changed in the last `DRIFT_WINDOW_DAYS` (7) and not yet referenced
   in `standard/`. PROPOSE (capped at `DRIFT_MAX_DRAFTS`=1, `claude -p --model sonnet`,
   `Read,Edit,Grep` only): DRAFT a foundation PR folding the lesson into the most relevant
   standard doc; size-capped (`DRIFT_MAX_FILES`=2 / `DRIFT_MAX_LINES`=80) → over-cap or
   no-edit or no-claude downgrades to a GitHub **issue** so the signal is never lost.
   **It NEVER merges — standard content is reasoning-authored, always human-reviewed**
   (there is no auto-merge path here, unlike Tier A). A one-time `--baseline` run seeds
   the dedup ledger (`standard-drift-proposed.json`) with the current backlog so the lens
   is **forward-looking** — it fires only on lessons that appear after the baseline.
   A full historical audit is a separate explicit run (clear the ledger + raise the cap).
4. **LEARN-BACK** — a note appended to `~/.whisky-os-state/dream-ledger.json` each run
   (dedupes across days + records what was done).

## The three tiers
- **Tier A — auto-fix → PR → auto-merge the safe tier.** ONLY if `can_auto_merge`
  (`ops/lib/dream-safety.sh`) returns `AUTOMERGE`: the fix class is in the safe
  allowlist `{dep-bump, leaf-override, lint, dead-code, doc-sync}`, the diff touches
  NO NEVER path, and it's ≤120 changed lines. `dream-fix.sh` opens a `dream-auto` PR
  and — only if `DREAM_AUTOMERGE=true` for that repo — enables **GitHub auto-merge**
  (`--auto --squash`, never `--admin`): the PR merges *only after all CI passes*, so a
  bad fix that fails CI never lands. A Telegram notice gives a veto window.
- **Tier B — propose.** Everything risky (major bumps, refactors, enhancements, anything
  on the NEVER list) → a `dream-proposal` GitHub issue + Telegram. Never merges.
- **Tier C — urgent.** A new CRITICAL/HIGH CVE on a prod dep → immediate alert.

## The NEVER list (auto-merge is forbidden if the diff touches any)
`payment · order · checkout · auth · login · session · token · rls · tenant ·
middleware · migrations · prisma/schema · .env · .github/ · packages/shared ·
packages/database`. Source of truth: `DREAM_NEVER_RE` in `ops/lib/dream-safety.sh`.

## Defense in depth (3 places assert the same gate)
1. **Local** — `dream-safety.sh` in `dream-fix.sh` decides whether to enable auto-merge.
2. **Server-side** — `template/.github/workflows/dream-automerge-guard.yml` (copied into
   each consumer repo) re-asserts NEVER-paths + size-cap on every `dream-auto` PR. It runs
   on `ubuntu-latest` (a self-hosted box is the thing we're guarding) and is a REQUIRED
   check — a wrong local box still can't auto-merge an unsafe change.
3. **CI** — the repo's normal gates + the scoped-audit + blast-radius must all pass before
   GitHub auto-merge completes.

## Kill switches + rollout
- `DREAM_AUTOMERGE` — **OFF by default on every repo.** Enablement is a repo-scoped
  allowlist (2026-07-12): a repo dir-name per line in
  `~/.whisky-os-state/dream-automerge-repos`, read by `dream_automerge_enabled()` in
  `ops/lib/dream-safety.sh` — auditable and revocable per repo, unlike a hardcoded
  global `DREAM_AUTOMERGE=true` (which `agent-security-scan.sh` flags). The
  `DREAM_AUTOMERGE` env var still overrides when set, for manual/CI runs. Add a repo
  to the allowlist only after: (a) one clean weekly dry-run, (b) ≥3 Tier-A PRs
  reviewed-as-correct, (c) the server-side guard is merged into that repo. Flagships
  (FWB/WBS) LAST. All other gates (safe tier, NEVER-paths, size cap, green CI) still
  apply regardless of allowlist membership.
- `DREAM_MAX_FIXES` (default 3) — caps auto-fixes per run.
- `DRY_RUN=1` — every script prints what it WOULD do, mutates nothing.

## Cadence + schedule
Daily 08:00 (`--daily`): research + dep-scan + act. Sunday also runs `--deep` (the heavy
lenses). On-demand: `bash ~/.claude/scripts/dream.sh --weekly --notify`. The runtime copies
live in `~/.claude/scripts` (launchd TCC rule); `ops/install.sh` deploys them.

## State files (`~/.whisky-os-state/`)
`world-digest.json` (LEARN) · `dream-findings.json` (SCAN) · `dream-ledger.json`
(dedup + learn-back, append-only) · `standard-drift-proposed.json` (STANDARD-DRIFT
dedup ledger — slugs already proposed/baselined).

**Source of truth:** this file + `docs/superpowers/plans/2026-06-10-full-dreaming-cycle.md`
+ `ops/lib/dream-safety.sh`. Every new safe-class or NEVER-path is added to dream-safety.sh
(+ the guard workflow's `NEVER_RE`, kept in lockstep) and noted here.
