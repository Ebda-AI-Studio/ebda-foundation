# Force AI Projects Tidy Report — 2026-06-09

Audited 7 projects under `~/Desktop/projects/`:
`force-website-builder`, `whatsapp-bulk-sender`, `Force_media_CRM`, `om-hassan-menu`, `mypovonai`, `digital-card`, `force-ai-foundation`.

Safety protocol followed: every item verified via `git check-ignore` before deletion. Only gitignored (or confirmed-regenerable in non-git context) artifacts deleted.

---

## DELETED (safe regenerable artifacts)

All items below were confirmed gitignored via `git -C <repo> check-ignore` before deletion.

### force-website-builder

| Path | Size |
|---|---|
| `dump.rdb` | 24K |
| `playwright-report/` | 520K |
| `coverage/` | 24K |
| `test-results/` | 4K |
| `apps/web/.next/` | 390M |
| `apps/admin/.next/` | 96M |
| `apps/api/dist/` | 6.8M |
| `packages/ui/dist/` | 572K |
| `packages/database/dist/` | 64K |
| `packages/shared/dist/` | 556K |
| `tsconfig.tsbuildinfo` | 452K |
| `packages/shared/tsconfig.tsbuildinfo` | 60K |
| `apps/web/tsconfig.tsbuildinfo` | 304K |
| `apps/admin/tsconfig.tsbuildinfo` | 436K |
| 16x `.DS_Store` files | ~64K |

**FWB subtotal: ~495M**

### whatsapp-bulk-sender

| Path | Size |
|---|---|
| `playwright-report/` | 520K |
| `coverage/` | 64K |
| `test-results/` | 4K |
| `.next/` (stray root-level) | 56K |
| `frontend/.next/` | 41M |
| `frontend/tsconfig.tsbuildinfo` | 408K |
| `logs/` | 2.2M |
| 5x `.DS_Store` files | ~20K |

**WBS subtotal: ~44.3M**

### Force_media_CRM

| Path | Size |
|---|---|
| `coverage/` | 1.7M |
| `.next/` | 199M |
| `tsconfig.tsbuildinfo` | 436K |
| 6x `.DS_Store` files | ~24K |

**CRM subtotal: ~201M**

### om-hassan-menu

| Path | Size |
|---|---|
| `.next/` | 610M |
| `tsconfig.tsbuildinfo` | 124K |
| 2x `.DS_Store` files | ~8K |

**om-hassan-menu subtotal: ~610M**

### mypovonai

| Path | Size |
|---|---|
| `.next/` | 10M |
| `tsconfig.tsbuildinfo` | 136K |

**mypovonai subtotal: ~10.1M** (media/ flagged below — not deleted)

### digital-card

| Path | Size |
|---|---|
| `.next/` | 50M |
| `test-results/` | 4K |
| `tsconfig.tsbuildinfo` | 172K |

**digital-card subtotal: ~50M**

---

**TOTAL RECLAIMED: approximately 1,410 MB (~1.4 GB)**

Breakdown: FWB ~495M + WBS ~44M + CRM ~201M + om-hassan-menu ~610M + mypovonai ~10M + digital-card ~50M

---

## FLAGGED FOR REVIEW (duplicates/stray — NOT deleted)

### 1. WBS `tsconfig.tsbuildinfo` — tracked by git despite being in .gitignore
**Path:** `~/Desktop/projects/Force-AI/internal-projects/whatsapp-bulk-sender/tsconfig.tsbuildinfo`
**Size:** 280K
**Reason:** `.gitignore` line 190 explicitly lists `tsconfig.tsbuildinfo`, but `git ls-files` shows it IS tracked (committed). Regenerable TypeScript build artifact. Should be removed from git tracking:
```bash
git -C ~/Desktop/projects/Force-AI/internal-projects/whatsapp-bulk-sender rm --cached tsconfig.tsbuildinfo
```

### 2. WBS `demo_contacts.csv` — test data at repo root, tracked by git
**Path:** `~/Desktop/projects/Force-AI/internal-projects/whatsapp-bulk-sender/demo_contacts.csv`
**Size:** 282 bytes
**Reason:** Tracked by git. Looks like a sample/test CSV uploaded to test the bulk-send feature. May be intentional (demo data for onboarding) or a leftover test file that should be in `.gitignore` or moved to `tests/fixtures/`.

### 3. WBS `test.csv` — bare test file at repo root, tracked by git
**Path:** `~/Desktop/projects/Force-AI/internal-projects/whatsapp-bulk-sender/test.csv`
**Size:** 55 bytes
**Reason:** Tracked by git. A 55-byte file named `test.csv` at the monorepo root is almost certainly a leftover from manual testing, not intentional source. Consider removing from git or moving to `tests/fixtures/`.

### 4. WBS `next-env.d.ts` at monorepo root — stray Next.js artifact, tracked
**Path:** `~/Desktop/projects/Force-AI/internal-projects/whatsapp-bulk-sender/next-env.d.ts`
**Size:** 228 bytes
**Reason:** WBS is a `backend/` + `frontend/` monorepo. Next.js lives in `frontend/`. A `next-env.d.ts` at the root level is generated when Next.js was accidentally run from the repo root. It is tracked by git. Should be removed from git and added to the root `.gitignore`. The legitimate one lives at `frontend/next-env.d.ts`.

### 5. CRM `test-results/` — Playwright artifacts NOT gitignored
**Path:** `~/Desktop/projects/Force-AI/internal-projects/Force_media_CRM/test-results/`
**Size:** 1.3M (19 files: failed-test screenshots + error-context.md files)
**Reason:** CRM's `.gitignore` is missing a `test-results/` entry (it has `/coverage`, `/build`, `*.tsbuildinfo` but not `test-results/`). The directory is NOT git-tracked (confirmed via `git ls-files`), but it is also NOT gitignored. Recommend adding `test-results/` to CRM's `.gitignore`, then deleting. Contents are stale Playwright failure screenshots from a previous test run.

### 6. CRM `reports/` — Stryker mutation report NOT gitignored
**Path:** `~/Desktop/projects/Force-AI/internal-projects/Force_media_CRM/reports/`
**Size:** 608K (single `mutation/mutation.html` file)
**Reason:** CRM's `.gitignore` has `stryker-tmp/` and `.stryker-tmp/` but NOT `reports/`. This is a Stryker mutation testing output directory. NOT git-tracked but NOT gitignored. Recommend adding `reports/` to CRM's `.gitignore`, then deleting.

### 7. mypovonai `media/` — 385M gitignored video pipeline I/O
**Path:** `~/Desktop/projects/mypovonai/media/`
**Size:** 385M (5 input videos + ~15 output video/image pairs)
**Reason:** Gitignored (`.gitignore` line 45: `media/`). Contents are raw input videos (`pov/`, `reel-ai-confident.mp4`, `smoke.mp4`, `test.mp4`, `tg_1.mp4`, `tg_2.mp4`, `tg_3.mp4`) and processed output pairs (`<id>.mp4` + `<id>.jpg`). These are runtime media-processing artifacts. Safe to delete if the source videos are backed up elsewhere, but held for explicit confirmation due to 385M size.
**Action needed:** Confirm source inputs are backed up, then `rm -rf ~/Desktop/projects/mypovonai/media/`

### 8. WBS `testsprite_tests/` — auto-generated test suite, gitignored
**Path:** `~/Desktop/projects/Force-AI/internal-projects/whatsapp-bulk-sender/testsprite_tests/`
**Size:** 384K (48 items: Python test files + `standard_prd.json`)
**Reason:** Gitignored (`.gitignore` line 181: `testsprite_tests/`). Auto-generated Python test files from a TestSprite run. Decision needed: if this test suite is useful, it should be committed (remove from `.gitignore`); if it was a one-off experiment, delete it.

### 9. FWB migration `20260524010000_store_bot_copy` — name looks suspicious but is legitimate
**Path:** `~/Desktop/projects/Force-AI/internal-projects/force-website-builder/packages/database/prisma/migrations/20260524010000_store_bot_copy/`
**Reason:** The `_copy` suffix made this look like a file duplicate artifact, but the migration SQL is legitimate: it adds a `bot_copy JSONB` column to `stores` for per-store WhatsApp bot wording overrides. The name means "bot copy" (marketing copy/messaging), not "a copy of a file". **No action needed — migration is correct and tracked.**

### 10. CRM `google-credentials.json` — live service account key on local disk
**Path:** `~/Desktop/projects/Force-AI/internal-projects/Force_media_CRM/google-credentials.json`
**Size:** 2.4K
**Reason:** Real Google service account credentials JSON file. Correctly gitignored. Not a deletable artifact (app needs it locally). Worth noting: production should source this from a secrets manager (Railway env var or GCP Secret Manager), not a local file. Verify the production Railway deployment uses env vars, not this file.

---

## Recommended follow-up fixes

1. **CRM .gitignore** — add these two entries:
   ```
   /test-results/
   /reports/
   ```
   Then delete both directories.

2. **WBS tsconfig.tsbuildinfo** — remove from git tracking:
   ```bash
   git -C ~/Desktop/projects/Force-AI/internal-projects/whatsapp-bulk-sender rm --cached tsconfig.tsbuildinfo
   git commit -m "chore: untrack tsconfig.tsbuildinfo (already in .gitignore)"
   ```

3. **WBS next-env.d.ts at root** — remove from git, add to root `.gitignore`:
   ```bash
   git -C ~/Desktop/projects/Force-AI/internal-projects/whatsapp-bulk-sender rm --cached next-env.d.ts
   echo "next-env.d.ts" >> ~/Desktop/projects/Force-AI/internal-projects/whatsapp-bulk-sender/.gitignore
   ```

4. **mypovonai media/** — confirm input videos are safe to lose, then delete the 385M.

5. **WBS testsprite_tests/** — decide: commit it (add to git, remove from .gitignore) or delete it.
