# 21 · Migration safety

**Concern:** changing a schema that live customers are already using, without an outage and without losing the ability to undo it.

`dr.md` covers "additive-only migrations" as one line inside disaster recovery. That is not enough. Migrations are their own failure surface, and on our stacks they are the one class of change that can take production down *at boot*, before a single request is served.

## The core rule — expand / contract, never replace

An AI asked to rename or restructure a column defaults to DROP + CREATE. On a live database every query hitting that column during the migration either fails or returns garbage.

Sequence every structural change as:

1. **Add** the new column/table/index — additive, nothing reads it yet.
2. **Backfill** data across.
3. **Switch** the application to the new shape (deploy).
4. **Drop** the old one — only after the switch is confirmed live, in a *later* migration.

Steps 1 and 4 are never in the same migration. If they are, it is a replacement, not a migration.

Anything that REJECTS data (triggers, CHECK, NOT NULL, UNIQUE, FK) follows the stricter companion rule in `migrations-backward-compatible.md`: it never ships ahead of the code that stops writing the old shape.

## Grading criteria

| # | Criterion | Severity |
|---|---|---|
| 21.1 | No migration both adds and drops the same logical field; drops ship in a later, separate migration | Critical |
| 21.2 | Every migration has a stated rollback path, written **at the same time** as the migration. If it cannot be described in reverse, it is not ready to run | Critical |
| 21.3 | Migrations are tested against a **current** mirror of production (real data shapes), not a stale copy and never first on prod | Critical |
| 21.4 | Every `CREATE INDEX` on a large or growing table carries a documented lock note + an out-of-band `CONCURRENTLY` escape hatch, and is written `IF NOT EXISTS` so pre-building is a clean no-op | High |
| 21.5 | Any constraint that can FAIL on existing data (UNIQUE, NOT NULL, FK, CHECK) has its violating-row query run against **production** immediately before shipping | Critical |
| 21.6 | Backfills carry a recency floor or an explicit "why unbounded is safe" note, so the first tick after deploy cannot re-process all history | High |
| 21.7 | `migrate diff` output is treated as a **lead, not ground truth** — every item confirmed against the live database before acting | High |
| 21.8 | Migrations that run on service boot are recognised as such: a failure there is an outage, not a red CI job | Critical |

## Traps, each learned from a real incident

**A failing constraint at boot is an outage.** Where migrations apply on API start (a previous storefront product does), a `CREATE UNIQUE INDEX` that violates existing data does not fail a pipeline — it fails the deploy and the service does not come up.

**Scope the violating-row check exactly like the index.** a previous storefront product 2026-08-08: `products` had a declared-but-never-created `@@unique([storeId, sku])`. The check `WHERE deleted_at IS NULL` returned 0 duplicates and looked safe. Prisma's plain unique index has **no WHERE clause**, so it also covers soft-deleted rows — and unfiltered there *was* a duplicate (a merchant soft-deleted a product and recreated it in another language reusing the SKU). The naive check would have shipped an outage. **Run the duplicate/violation query with the same predicate the index will have — which for a plain index means no predicate at all.**

**Soft delete almost always means the constraint must be partial.** Uniqueness belongs among live rows; blocking reuse of a deleted row's natural key is a product regression, not integrity.

**Partial and expression indexes are permanent ORM drift.** Prisma cannot express `WHERE`, so `migrate diff` reports a partial index as missing forever. Accept and document it; never "fix" it by adding a duplicate full index, and never let `migrate dev` regenerate the plain version.

**A declared index is not an existing index.** If a migration never created it, it is absent from production no matter what the schema file says — and the ORM will happily plan queries as if it were there.

**`migrate diff --from-migrations` describes the migrations folder, not production.** a previous storefront product 2026-08-08: production reported all 110 migrations applied and the folder held exactly 110, yet its DDL did not match replaying them — out-of-band DDL had been applied. Two "findings" evaporated on contact with the live database (columns that did not exist; an index that already did).

**Never resolve accumulated drift by committing `migrate dev` output.** It will generate destructive DDL — column drops, NOT NULL forcing, index renames — mixed in with what you wanted. Ship intended changes as individual reviewed migrations.

## Verify

- Replay the full migration folder into a shadow DB and diff against the schema; confirm no *new* drift for the objects you touched.
- Confirm the constraint actually enforces: attempt a violating write inside a transaction and roll it back.
- After a boot-time migration deploys, confirm it is recorded applied (`_prisma_migrations`) — an index existing does **not** prove your migration created it.
