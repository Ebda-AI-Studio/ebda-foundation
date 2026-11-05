# dr — Disaster Recovery & Backup Rubric

tags: [BOTH]
sources: PLAYBOOK §10 (Data lifecycle + DR), CLAUDE.md (production rollback + backup discipline), reference-iceberg-audit.md (terms 21 DR / 29 Rollbacks / DR-drill), reference-force-ai-production-grade-standard.md (layer 3: data — snapshots, rollback kit)

## What "solid" looks like
A scheduled, restorable DB backup that dumps full data (RLS tables included) independent of repo `.env`; a `scripts/rollback.sh` that reverts code and blocks on migrations; migrations that are additive-only by default so an auto-applied schema bug is forward-compatible; a `docs/ROLLBACK.md` with concrete recovery paths; RLS policy state re-verified after any restore; and the whole snapshot → rollback → restore loop rehearsed, not discovered mid-incident.

## Criteria
| # | Criterion | Solid (grade 2) | Gap detection | Severity |
|---|---|---|---|---|
| 1 | Scheduled restorable DB backup | A backup job dumps the prod DB on a schedule (daily local `pg_dump`), keeps last ~30, prunes older | file-exists `scripts/backup-db.sh` or `backup-all-neon.sh`; confirm a scheduler (launchd plist / cron / workflow) invokes it | Critical |
| 2 | Backup independent of repo `.env` + dumps full data | Backup pulls the DIRECT connection string from the provider (`neonctl --role-name neondb_owner`), not repo `.env` (which may hold placeholders/pooled URLs) | grep backup script for `neonctl`/direct-URL retrieval; confirm it does NOT read `DATABASE_URL` from `.env`; confirm dump role is the owner (sees RLS tables) | High |
| 3 | `pg_dump` version ≥ server version | `pg_dump` major version ≥ Neon server (PG17) — older silently produces empty dumps | grep backup script / docs for a pinned `pg_dump`/`postgresql@17` path; check `pg_dump --version` ≥ server | High |
| 4 | `scripts/rollback.sh` present, blocks on migrations | `scripts/rollback.sh` does git revert + push and refuses/warns when the revert spans a migration | file-exists `scripts/rollback.sh`; grep it for a migration guard (`migration`/`prisma migrate`/block) | High |
| 5 | `docs/ROLLBACK.md` with recovery paths | `docs/ROLLBACK.md` documents the distinct recovery paths (e.g. 3) | file-exists `docs/ROLLBACK.md`; grep for enumerated recovery paths | Medium |
| 6 | Migrations additive-only by default | Auto-applied committed SQL is additive (nullable columns, new tables); destructive/RENAME/NOT-NULL-no-default needs a written plan + snapshot | grep `prisma/migrations/**` for `DROP TABLE`/`DROP COLUMN`/`RENAME`/`ALTER ... NOT NULL` without a default; flag any not paired with a plan doc | Critical |
| 7 | Generated migrations inspected for drift drops | When local DB drifts from target, the generated migration is inspected for `DROP`/`RENAME` before commit (drift once auto-generated a prod-table DROP) | grep latest `prisma/migrations/**/migration.sql` for `DROP`/`RENAME`; confirm none unreviewed | Critical |
| 8 | RLS re-verified after restore | After any snapshot restore, RLS policy state is re-verified (runtime depends on policy shape) | grep `docs/ROLLBACK.md`/restore script for an RLS re-verify step; SQL check shape `SELECT * FROM pg_policies` post-restore | High |
| 9 | DB branch hygiene | Only `production`/`main` (+ `preview` when staging is real); no stray `test-*`/`prod-<sha>`/`e2e-*` snapshot branches piling up | list provider branches (`neonctl branches list`); confirm count under the free cap (~10) and no orphan snapshot branches | Medium |
| 10 | Snapshot + rollback + restore rehearsed | The full DR loop is rehearsed (DR-drill), not discovered during an incident; local/staging never touch prod during the drill | grep `docs/ROLLBACK.md` for a rehearsal/drill note; confirm restore target is non-prod | High |

## Evidence (filled during audit, per repo)
- FWB: …
- WBS: …
