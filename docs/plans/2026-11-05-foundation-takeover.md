# Ebda Foundation takeover: the AI OS + shared product code, off Force AI

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `Ebda-AI-Studio/ebda-foundation` becomes the single source of Ahmad's engineering OS (the "Whisky AI OS": ops runtime, hooks, standards, agents, skills, memory/dream bridge, dashboard, watchers) AND the shared product library, so that `force-ai-foundation` can be frozen now and later deleted from this Mac with nothing breaking.

**Architecture:** One repo, two layers with a hard boundary: `os/` (the machine OS, installed into `~/.claude` by `os/install.sh`) and `packages/foundation` + `create/` (the product library and scaffold from the 2026-10-26 plan, vendored into products by the `ebda-foundation` CLI). Everything is ported from force-ai-foundation `master` (not from `~/.claude/scripts`, which is stale), generalised behind one config file, and stripped of Force AI brand, client data and secrets. Cutover of the Mac is one script that swaps the installed OS from the old source to the new one and proves it.

**Tech Stack:** bash (macOS + Linux guests), node ≥ 22 `.mjs`, Python 3 for existing `lib/*.py`, launchd, git hooks, TypeScript (product library), vitest, GitHub Actions on `vars.EBDA_RUNS_ON`.

**Spec:** Ahmad, 2026-11-05 (chat): "ebda-foundation … has to take everything from force ai and enhance it ebda way"; scope = EVERYTHING; users = every business now; "Whisky AI OS belongs to ebda foundation, force ai foundation will stop"; "I own the code and the right to take the code"; he is leaving Force AI and will later purge Force AI from the Mac. Memory: `project-ebda-foundation-replaces-force-ai-foundation`. Prior plan (product library, F0–F11): `business/ebda/plans/2026-10-26-ebda-foundation.md`. Inventory: controller session ad1f1e34, 2026-11-05 (summarised in §Inventory below).

## Global Constraints

- Source of truth for every ported file: `force-ai-foundation` at the tag `final-before-ebda` (Task 0), never `~/.claude/scripts` (12 installed scripts are older than master).
- No string in `ebda-foundation` may match `ForceAI-KW|force-ai-foundation|Force-AI/internal-projects|forceai\.|com\.forceai|ff6e01|#ff6e01|Kuwait|KWD|MyFatoorah|aladiyat|rayanah|om-hassan|da-gusto|fca-kuwait|salam-hydraulic` outside `docs/history/` (enforced by `os/tests/no-force-strings.test.sh`).
- One config file `os/config/os.env` (committed, no secrets) holds `OS_HOME`, `OS_REPO_SLUG=Ebda-AI-Studio/ebda-foundation`, `OS_ORGS="Ebda-AI-Studio Whisky-11 voidengineer-911"`, `OS_LAUNCHD_PREFIX=com.ebda.os`, `OS_GIT_CHAIN_KEY=ebda.chainHusky`; every script reads it via `os/ops/lib/os-config.sh`. Per-machine overrides in `~/.ebda-os.local.env` (gitignored, never committed).
- Secrets never enter the repo: `~/.whisky-services.env` stays where it is (renamed later only by an explicit task), `.gitleaksignore` is re-baselined, gitleaks runs in CI.
- Client and finance data never move: `backup-aladiyat.sh`, `cost-clients.json`, `fleet-stores.json` (real list), `accountant/` real config, `workers/client-media`, `ops/client-media`, `docs/data/*inventory*`, `docs/r2-bucket-inventory.md`, Force/client plans in `docs/plans/`, `audit/` sweeps naming clients, `template/` (FWB-shaped). Fleet lists become `os/config/fleet.example.json` + a gitignored local file.
- Resource-frugal by design (memory `feedback-resource-frugal-by-design`): watchers skip work when nothing changed, poll slowly, CI affected-only; every PR states its footprint.
- Ebda rules: no orange, never bare "Ebda" in copy, Arabic-first for any UI (dashboard copy in en+ar), impeccable for UI changes.
- Merge only via the repo's own `ops/merge-gate.sh`; commitlint as in ebda-store; never `--no-verify`; `git add` explicit paths.
- Do NOT delete, archive or modify anything in `ForceAI-KW` or `Force-AI/` on the Mac except: tagging `final-before-ebda` and parking open work (Task 0). The purge is a separate, Ahmad-triggered task (Task 9 only CHECKS readiness).

## Review Focus

1. **Double install:** the old `com.forceai.*` jobs and the new `com.ebda.os.*` jobs both loaded → two dream runs, two hygiene sweeps fighting over worktrees. Expect: the cutover boots out every `com.forceai.*` label before bootstrapping any `com.ebda.os.*` one, and `os-selftest` fails if both prefixes are loaded. (Test in Task 7.)
2. **Dangling symlinks after purge:** `~/.claude/agents/*`, `~/.claude/skills/{benchmark-vet,blast-radius,correct}` still pointing into force-ai-foundation. Expect: `force-purge-check.sh` exits 1 naming each. (Task 9.)
3. **Hardcoded path survives the port:** a script still defaulting to `~/Desktop/projects/Force-AI/...` silently no-ops (memory pipeline `sync_foundation`, `dream-standard-drift` `FND`). Expect: the string test fails the PR. (Task 2 test, run on every task.)
4. **Linux guests (Umbra):** ported scripts that use macOS-only tools (`lockf`, `stat -f`, `security`, `launchctl`) break CI runners. Expect: each script either guards with `uname` or is listed macOS-only in `os/MANIFEST.md`; `shellcheck` + a Linux container smoke run in CI. (Task 2.)
5. **Keychain hex:** any ported script reading a multi-line secret via `security find-generic-password -w` gets hex. Expect: all go through `os/ops/lib/keychain.sh` (port of ebda-store `scripts/cf/lib/keychain.mjs` logic). (Task 2.)

---

## Inventory (what exists today)

- force-ai-foundation: `ops/` 126 scripts + `lib/` 118 + `hooks/` 9 + 49 launchd templates + `remediation/ watchers/ detectors/ journeys/ dashboard/ command-center-app/ git-hooks/ accountant/ cloud/`; `standard/` 95; `docs/` 55; `agents/` 25; `skills/` 4 (benchmark-vet, blast-radius, correct, force-audit); `audit/` 14; `schemas/` 1; `tests/` 19; `vendor/landlock-run`; `workers/{event-relay,client-media}`; `packages/force-config`; `template/` 37; root `ARCHITECTURE.md`, `PRODUCTION-SAAS-BUILD-PLAYBOOK.md`, `CLAUDE.md`.
- Install model: `ops/install.sh` COPIES scripts into `~/.claude/scripts`, renders `com.forceai.*` plists into `~/Library/LaunchAgents`, SYMLINKS 25 agents + 3 skills, sets global `core.hooksPath=~/.claude/git-hooks`, sets `forceai.chainHusky`. Hooks in `~/.claude/settings.json` call the installed copies only.
- Hard ties to the old source on this Mac: 25 agent symlinks, 3 skill symlinks; hardcoded paths in `update-memory-pipeline.sh:750,866`, `dream-standard-drift.sh:81-82,92,139,210-238`, `sync-foundation.sh:49`, `drift-watch.sh:25`, `os-selftest.sh:51`, `dead-gate-detect.sh:36`, `agent-dispatch.sh:131-132`, `self-check.sh:329`; org `ForceAI-KW` in ~30 scripts; `~/.claude/CLAUDE.md` lines 9, 68, 106.
- ebda-foundation today: `main` = init; open PR #1 (`feat/f0-seed`: brand, tokens, phone, buyer, text, slugs, vectors, CI, merge-gate, host-lock, workflow-lint), PR #2 (`feat/foundation-v0`: v0.1.0 + CLI sync/check/status/new + parity template); branches `feat/f1-cli`, `feat/f11-scaffold`.
- External consumers of the old source NOT moved by this plan (Force AI's business): `Force_media_CRM` reusable CI, client repos' docs, `salam-hydraulic/ERP`, Force runners `fwb-ci6-force-ai-foundation-*`.

## Target layout

```
ebda-foundation/
  os/                         the AI OS (installed into ~/.claude by os/install.sh)
    config/os.env             committed defaults (Global Constraints)
    config/fleet.example.json example fleet/watch list (real list: ~/.ebda-os.local.json)
    ops/                      scripts (*.sh, *.mjs, *.py) + lib/ remediation/ watchers/ detectors/ journeys/ hooks/ git-hooks/
    launchd/                  com.ebda.os.<name>.plist templates
    dashboard/                server.mjs, state-aggregator.mjs, public/ (en+ar)
    command-center-app/       SwiftUI app (sources only)
    standard/                 graded engineering standards (00-index.md)
    agents/  skills/  schemas/  vendor/landlock-run/
    tests/                    bash + node tests, incl. no-force-strings, install dry-run, selftest
    install.sh  cutover.sh  MANIFEST.md
  packages/foundation/        product library (PRs #1/#2, plan 2026-10-26 F0–F11)
  create/skeleton/            new-product scaffold (F11)
  bin/ebda-foundation.mjs     product CLI (sync|check|status|new)
  docs/  (plans/, rulings/, runbooks/, history/)   PRODUCTION-SAAS-BUILD-PLAYBOOK.md  ARCHITECTURE.md
  .github/workflows/ci.yml    product tests + os tests (shellcheck, Linux container smoke, string test)
```

---

### Task 0: Freeze and tag the old source

**Files:** none in ebda-foundation; `docs/history/force-ai-foundation-freeze.md` (created in Task 1).

- [ ] **Step 1:** In force-ai-foundation, list open work: `git status --short`, `git worktree list`, open PRs (`gh pr list --repo ForceAI-KW/force-ai-foundation`), the untracked `docs/plans/2026-10-31-force-crm-landings-to-cloudflare.md`. Report them to Ahmad; land or close only what he says (default: leave as is, they are Force AI's).
- [ ] **Step 2:** Tag `master` as `final-before-ebda` and push the tag (`git tag -a final-before-ebda -m "frozen; successor Ebda-AI-Studio/ebda-foundation"`). Record the sha.
- [ ] **Step 3:** Verify: `git ls-remote --tags origin final-before-ebda` returns the sha.

### Task 1: Land the product-library PRs and the layout

**Files:** merge PR #1 then #2 (rebase onto main if needed); Create `os/MANIFEST.md`, `os/config/os.env`, `docs/history/force-ai-foundation-freeze.md`, `docs/rulings/FDN-OS-1.md`, `README.md` (two-layer explanation).

**Interfaces — Produces:** `os/config/os.env` keys `OS_HOME OS_REPO_SLUG OS_ORGS OS_LAUNCHD_PREFIX OS_GIT_CHAIN_KEY OS_STATE_DIR=~/.whisky-os-state OS_SERVICES_ENV=~/.whisky-services.env`.

- [ ] **Step 1:** Review PR #1/#2 diffs against the 2026-10-26 plan; rebase, CI green, merge via `ops/merge-gate.sh` (positional args first). Re-tag v0.1.0 at the merged commit if the sha changed (PR #2 body says consumers lock the commit).
- [ ] **Step 2:** Write `docs/rulings/FDN-OS-1.md`: decision = one repo, two layers (`os/`, `packages/`), source `final-before-ebda`, prefix `com.ebda.os`; evidence = Ahmad 2026-11-05; cost if wrong = splitting later is a `git filter-repo` of `os/`.
- [ ] **Step 3:** Commit + PR + merge-gate.

### Task 2: Port the OS core (generic ops + libs + hooks), generalised

**Files:** Create `os/ops/**` from `final-before-ebda:ops/**` EXCLUDING the client/finance list in Global Constraints and the Force-only scripts (`wbs-*.sh`, `checkout-monitor.sh`, `backup-*.sh` for client DBs, `auto-fix-telegram-*` only if it hardcodes Force chats — check); Create `os/ops/lib/os-config.sh`, `os/ops/lib/keychain.sh`; Create `os/tests/no-force-strings.test.sh`, `os/tests/linux-smoke.test.sh`; Modify `.github/workflows/ci.yml` (shellcheck, string test, Linux smoke in `ubuntu-24.04` / `vars.EBDA_RUNS_ON`).

**Interfaces — Produces:** `os_config_load` (bash fn, sources `os.env` then `~/.ebda-os.local.env`); `keychain_get <service>` (prints the secret, hex-decoded when the raw output is pure even-length hex and decodes to text containing a newline or a known prefix).

- [ ] **Step 1: Write the failing string test** `os/tests/no-force-strings.test.sh`: greps the repo (excluding `docs/history/`, `.git/`) for the Global Constraints regex; exit 1 with file:line list when any match.
- [ ] **Step 2:** Copy the files; run the test → FAIL listing the hardcoded hits (expected: ~30 org slugs, the 8 path scripts).
- [ ] **Step 3:** Replace every hit with `os-config.sh` variables (`$OS_REPO_SLUG`, `$OS_ORGS`, `$OS_LAUNCHD_PREFIX`, `$OS_GIT_CHAIN_KEY`, `$OS_HOME`); scripts that only made sense for Force fleets read the fleet from `~/.ebda-os.local.json` and do nothing (exit 0, one log line) when it is absent.
- [ ] **Step 4:** Port the 41 `ops/tests` + `tests/remediation`; run them: `bash os/tests/run-all.sh` → all PASS.
- [ ] **Step 5:** `shellcheck -S warning os/ops/*.sh os/ops/lib/*.sh` → 0 warnings; Linux smoke (`bash -n` + `--help` on every script in a `node:22` container) → PASS; mark macOS-only scripts in `os/MANIFEST.md`.
- [ ] **Step 6:** String test → PASS. Commit + PR (footprint: CI minutes added per PR).

### Task 3: Port standards, docs, agents, skills, schemas, vendor, playbook

**Files:** Create `os/standard/**` (95), `os/agents/*.md` (25), `os/skills/{benchmark-vet,blast-radius,correct}/**`, `os/schemas/hooks.schema.json`, `os/vendor/landlock-run/**`, `PRODUCTION-SAAS-BUILD-PLAYBOOK.md`, `docs/runbooks/**` (generic only), `docs/ai-market-doctrine.md`; NOT `skills/force-audit` (open decision kept in `docs/history/`).

- [ ] **Step 1:** Copy; run the string test → FAIL on Force examples inside standards (e.g. FWB incidents). Rewrite each as a neutral example or move the incident narrative to `docs/history/` with a link.
- [ ] **Step 2:** `standard/00-index.md` links resolve: a node script `os/tests/standard-links.test.mjs` asserts every relative link in `os/standard/**` points at an existing file → PASS.
- [ ] **Step 3:** Commit + PR.

### Task 4: Port the AI OS components

**Files:** Create `os/dashboard/**` (Ebda palette: night + gold `#B08D57`, en+ar labels, RTL-correct), `os/command-center-app/**` (sources; `.build` excluded), dreaming (`dream*.sh`, `lib/dream-safety.sh`, `instinct-*.sh`), self-heal + remediation (`self-heal.sh`, `heal-*.sh`, `remediate.sh`, `remediation/**`, `lib/heal-registry.example.json`), rt-transport (`dispatch.sh`, `event-listener.sh`, `emit-event.sh`, `lib/work-registry.sh`, `watchers/**`), page-load (`page-load-monitor.sh`, `journeys/page-load/**` reading the fleet from local config), companion (`daily-brief.sh`, `lib/daily-brief-synth.py`, `cost-attribution.sh`, `code-health-scan.sh`, `acceptance-feedback.sh`).
**Not ported:** `workers/event-relay` (Force Cloudflare account) → new `os/workers/event-relay` only if Ahmad wants the remote relay on the Ebda account (record as open decision OD-2).

- [ ] **Step 1:** Port + string test + component tests (`tests/remediation`, dashboard aggregator unit test) → PASS.
- [ ] **Step 2:** Frugality pass: every watcher/dream step checks a content digest or mtime and exits early when unchanged; document per-component polling interval in `os/MANIFEST.md`; no loop polls `gh` faster than every 5 min.
- [ ] **Step 3:** impeccable critique on the dashboard (Arabic + English) before commit.
- [ ] **Step 4:** Commit + PR.

### Task 5: New installer (`os/install.sh`) with the `com.ebda.os` prefix

**Files:** Create `os/install.sh`, `os/launchd/com.ebda.os.*.plist` (rendered from the 49 templates, renamed), `os/install-hooks.sh`, `os/tests/install-dryrun.test.sh`.

**Interfaces — Produces:** `os/install.sh [--dry-run] [--home DIR]`: copies `os/ops/**` → `$HOME/.claude/scripts/`, renders plists with `__HOME__`/`__PATH__` into `$HOME/Library/LaunchAgents/`, symlinks `os/agents/*.md` and `os/skills/*` from a checkout on `main` only, installs git-hooks + `core.hooksPath`, sets `$OS_GIT_CHAIN_KEY` on trusted husky repos (`lib/trusted-origin.sh` with `$OS_ORGS`). Refuses to run when any `com.forceai.*` label is loaded (prints `run os/cutover.sh`).

- [ ] **Step 1: Failing test** `install-dryrun.test.sh`: `--dry-run --home $(mktemp -d)` prints the planned copy/link/bootstrap list; asserts 0 lines mention `forceai`, every symlink target is under the repo, plist count = template count.
- [ ] **Step 2:** Implement; test → PASS; second run is idempotent (no diff).
- [ ] **Step 3:** Commit + PR.

### Task 6: Repoint memory, dream bridge and the instructions

**Files:** Modify `os/ops/update-memory-pipeline.sh` (`sync_foundation` → `$OS_HOME`), `os/ops/dream-standard-drift.sh` (`FND=$OS_HOME`, `SLUG_REPO=$OS_REPO_SLUG`, standard path `os/standard`), `os/ops/sync-foundation.sh`, `os/ops/sync-agents-md.sh`; Modify `~/.claude/CLAUDE.md` lines 9, 68, 106 (dual-authorship rule → "a foundation PR into `ebda-foundation/os/standard/` or `os/ops/`"; standards path `ebda-foundation/os/standard/…`) — done by the controller after the Task 7 cutover, not by a subagent.

- [ ] **Step 1:** Unit test for the bridge with a temp memory dir + temp foundation: a memory file with the sentinel and a new slug → the script plans a draft PR against `$OS_REPO_SLUG` (dry-run), never `ForceAI-KW`.
- [ ] **Step 2:** The ledger `~/.whisky-os-state/standard-drift-proposed.json`: slugs proposed to the old repo are re-proposed once to the new repo (flag `--reseed`), so no lesson is lost.
- [ ] **Step 3:** Commit + PR.

### Task 7: Cutover of this Mac (controller runs it, Ahmad watching)

**Files:** Create `os/cutover.sh`, `os/tests/selftest-no-dual.test.sh`; Modify `os/ops/os-selftest.sh` (fail when both `com.forceai.*` and `com.ebda.os.*` are loaded; fail when any `~/.claude/agents|skills` link points outside `$OS_HOME`).

**Interfaces — Produces:** `os/cutover.sh [--dry-run]`: (1) snapshot `~/.claude/{scripts,agents,skills,git-hooks}` + `~/Library/LaunchAgents/com.forceai.*` to `~/.claude/backups/pre-ebda-os-<ts>.tar.gz`; (2) `launchctl bootout gui/$UID/<label>` for every `com.forceai.*`; (3) remove the old plists (they are in the snapshot); (4) `os/install.sh`; (5) `os-selftest.sh` + `self-check.sh`; (6) on any failure: restore the snapshot and re-bootstrap the old labels (prints exactly what it restored).

- [ ] **Step 1:** `--dry-run` on the Mac → plan lists 51 bootouts, N installs, 0 conflicts.
- [ ] **Step 2:** Real run; then verify: `launchctl list | grep -c com.forceai` = 0; `launchctl list | grep -c com.ebda.os` = expected count; `readlink ~/.claude/agents/*` all under `$OS_HOME`; one manual tick of `dream`, `workspace-hygiene`, `update-memory-pipeline.sh all` succeeds with logs.
- [ ] **Step 3:** Controller edits `~/.claude/CLAUDE.md` (Task 6 lines) and runs the memory pipeline; confirms `~/AGENTS.md` regenerated without `force-ai-foundation`.

### Task 8: Product library continuation + consumers

**Files:** per the 2026-10-26 plan F2–F11, with these changes: the bump bot plist moves to `os/launchd/com.ebda.os.foundation-bump.plist` (was `force-ai-foundation/ops/`); `ebda-foundation-bump.sh` ported into `os/ops/`; ebda-store `scripts/ci/{merge-gate,host-lock}.sh` become thin wrappers over the vendored `scripts/foundation/` copies (one canonical version: diff SRC `host-lock.sh` (re-entrant fix 2026-10-25) vs DST before choosing — keep the re-entrant one).

- [ ] **Step 1:** Execute F2–F11 as written there (each its own PR with the verification column), consumers ebda-store + ebda-whatsapp (+ ebda-studio when it has code).
- [ ] **Step 2:** `ebda-foundation status` shows both consumers on the latest tag.

### Task 9: Purge readiness check (no deletion)

**Files:** Create `os/ops/force-purge-check.sh`, `os/tests/force-purge-check.test.sh`.

**Interfaces — Produces:** `force-purge-check.sh` exits 0 only when: no `~/.claude/**` symlink resolves into `Force-AI/`; no file under `~/.claude/scripts`, `~/.claude/settings*.json`, `~/Library/LaunchAgents`, `~/.claude/CLAUDE.md`, `~/AGENTS.md` names `force-ai-foundation|ForceAI-KW|com.forceai`; no non-Force repo under `~/Desktop/projects/{Ebda-AI-Studio,Whisky-11,Personal}` references `force-ai-foundation` (docs included, listed); the memory vault remote is not `ForceAI-KW/*` (open decision OD-1). Otherwise exit 1 with every hit.

- [ ] **Step 1: Failing test** with a fake HOME containing one dangling agent symlink and one `com.forceai.x` plist → exit 1 naming both.
- [ ] **Step 2:** Implement → PASS; run on the Mac after Task 7 → report remaining hits to Ahmad.
- [ ] **Step 3:** The purge itself (deleting `Force-AI/`, Force worktrees, `~/.claude/projects/*Force*` dirs, revoking access) is NOT in this plan: it runs only when Ahmad says he has left and asks for it.

## Open decisions (Ahmad)

- **OD-1 memory vault:** `os-recall.sh` points at `ForceAI-KW/claude-memory-vault`; CLAUDE.md says the vault is personal (`voidengineer-911`). Move the remote to `voidengineer-911` (or `Ebda-AI-Studio`) before the purge? Default: `voidengineer-911` (it is personal).
- **OD-2 event relay Worker:** re-deploy `event-relay` on the Ebda/personal Cloudflare account, or drop the remote relay (local only)? Default: drop until needed (frugal).
- **OD-3 Umbra:** `umbra` (ForceAI-KW) runs Ebda CI today. Move it to `Ebda-AI-Studio` with the OS, or keep using it as-is until the purge? Default: move with the OS (it is part of the machine OS; Ebda CI depends on it).
- **OD-4 env + state names:** rename `~/.whisky-services.env` / `~/.whisky-os-state` to `~/.ebda-os/…`? Default: keep the names (no value in churn; they are not Force-branded).

## Finish line

1. `force-purge-check.sh` exits 0 on the Mac (except items Ahmad keeps on purpose, listed).
2. `launchctl list` shows only `com.ebda.os.*` OS jobs; `os-selftest.sh` PASS; dream, hygiene and memory pipeline ran once each from the new install.
3. ebda-foundation CI green: product tests, os tests, string test, shellcheck, Linux smoke.
4. ebda-store and ebda-whatsapp on the latest foundation tag; parity tests green.
5. Must NOT change: production behaviour of any product; FWB/WBS (Ahmad decides next week); anything inside `ForceAI-KW` beyond the `final-before-ebda` tag.

Order: 0 → 1 → (2 ∥ 8-early) → 3 → 4 → 5 → 6 → 7 → 9 → 8-rest. Tasks 2–6 are code-only (parallel-safe in separate worktrees after Task 1 lands the layout); Task 7 touches the live Mac and runs alone.

## Amendment A (Ahmad, 2026-11-05 late): where the OS runs

**Decisions (binding, supersede anything above that conflicts):**
- GitHub stays (code, PRs, CI). **GitHub Actions minutes are for CI only** — the OS never spends them on its own work (no fix jobs, no dream runs, no watchers on Actions).
- The always-on part of the OS moves to **Cloudflare Workers** on the personal account (69188202…): watchers (Cron Triggers), the finding → job queue (Durable Object / Queue), the event relay (GitHub org webhooks → KV queue), the Telegram policy (unhealed P1 + real decisions + one daily digest, ≤ 3/day, deduped — memory `feedback-os-acts-not-pings`), and the ops dashboard (Worker + static assets, behind Cloudflare Access).
- The "hands" (Claude Code writing fixes) run behind one provider interface: **Cloudflare Container/Sandbox = default, but ONE batched Linux container run per day** (end of day, e.g. 23:30 Cairo) that drains the whole day's job queue sequentially, then exits; the **Mac = fallback / on-demand** provider when awake. Nothing else starts a container (frugal rule). P1 incidents that the self-heal recipes cannot fix are queued for the nightly batch and messaged once.
- The git host stays behind an interface (GitHub today) so it can change later without a rewrite.

**What this changes in the tasks:**
- Task 4 becomes two tasks: **4a** port the AI-OS logic as Worker code under `os/cloud/brain/` (cron watchers, job queue DO, relay, Telegram policy + digest, dashboard) with workerd tests; **4b** `os/cloud/hands/`: a container image (node 22, git, gh, Claude Code CLI, repo toolchains) + `run-batch.mjs` that pulls the day's queue, runs each job in its own worktree with a per-job time cap and the Claude usage guard (stop at the configured weekly-usage threshold), opens PRs, writes outcomes back to the brain, and exits. Provider interface `hands/providers/{cloudflare-sandbox,mac-local}.mjs` (+ optional `github-actions.mjs`, disabled by default).
- Auto-merge only for the pre-approved classes (dependency/CVE bumps, docs, tests, lint, flaky fixes) and only when the repo's merge gate is green; everything else is a PR + one question.
- Task 5's launchd set shrinks to the Mac-only jobs (Umbra guard/maintenance, local hygiene, memory pipeline, mac-local hands provider).
- Task 7 cutover: deploy the brain Worker + relay + webhooks, then swap the Mac's launchd set.
- Footprint target: Workers + cron + DO + KV inside the $5 plan; one container run/day ≈ well inside the included 375 vCPU-min / 25 GiB-h per month; GitHub minutes used by the OS: 0.

**Amendment A.1 (Ahmad, 2026-11-05): urgent jobs get an immediate container.** The brain starts an on-demand container run at once (not waiting for the nightly batch) only for an URGENT job, defined strictly as one of: (1) a production outage or broken money path (checkout, payment webhook, payout) that the self-heal recipes did not fix within their retry budget; (2) a security issue in deployed code or a deployed dependency that is critical (CVSS ≥ 9.0) or listed as known-exploited (CISA KEV); (3) a data exposure (PII/secret leak) detected by a watcher. Guards: max 3 urgent runs per day and 1 at a time (further urgent jobs queue behind it); each run handles that one job with a 30-minute cap; the usage guard still applies; the job's outcome (PR / fix deployed / could not fix) is sent as ONE Telegram message. Anything not matching (1)-(3) waits for the nightly batch. The urgency classifier is unit-tested with examples of each class and of near-misses (a CVSS 8.8 dev-only dependency → nightly).
