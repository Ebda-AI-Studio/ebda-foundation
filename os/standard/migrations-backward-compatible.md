# Migrations must be backward-compatible with the running release

**Concern:** a migration runs BEFORE the code that needs it ships, and the code it replaces can still be running, or be redeployed by a rollback. The schema must therefore work for the release in production and for the release a rollback returns to.

sources: Ebda Store audit 2026-11-12 (backfill-data-jobs, P2-2; Ruling SKIN-DEL-10). Companion to `migration-safety.md` (expand/contract for column changes); this file is the rule for anything that REJECTS data.

## Why

On Cloudflare the deploy order is `wrangler d1 migrations apply` first, `wrangler deploy` second. For that window, and for as long as a rollback lasts, old isolates write against the new schema. Ebda Store D1 0009 / StoreDO 0004 remapped retired skins and added `BEFORE INSERT/UPDATE` triggers that `RAISE(ABORT)` on a retired template: an old isolate writing one got a 500, a code rollback left the triggers in place, and a backup replayed into a database built from the migrations hit them too.

## The rule

1. **Expand only before the deploy.** A migration that ships ahead of its code may add: nullable or defaulted columns, tables, indexes, permissive triggers. It may not add anything that rejects a value the running release can write.
2. **New code tolerates old values.** Readers map or ignore any value the previous release stored; writers accept or normalise the previous release's values instead of failing. Never make the DATABASE the first place a legacy value is refused.
3. **Contract one release later.** Rejecting triggers, CHECK/NOT NULL/UNIQUE tightening, FK additions on live data, column or table drops ship in a LATER migration, only after (a) the code that stopped writing the old shape has been live a full release, (b) the previous release (the rollback target) writes none either, and (c) a prod read-only query shows zero violating rows. Park the contract migration outside the applied migrations directory with the gate in its header, and record the gate in a ruling; do not number it into the live directory early.
4. **Rollback must work.** For every migration, deploy the previous release against the post-migration schema (or run its tests against it) and confirm it still reads and writes. Undo steps are written with the migration.
5. **Backups from the previous release must load.** Restore the last backup of the previous release (schema and rows, and rows into a database built from the migrations) into the post-migration schema; a test pins it. A restore that fails on the new constraints is a failed rollback.
6. **Applied migrations are never edited.** Ledgers (`d1_migrations`, a Durable Object's `_migrations`, `_prisma_migrations`) key on the name, so editing the text changes nothing in prod and only makes fresh databases disagree with live ones. Fix forward with a new numbered migration.
7. **A lossy data move keeps the original** (a nullable `<col>_original`, or an audit row) so it can be reverted.

## Grading criteria

| # | Criterion | Severity |
|---|---|---|
| MBC.1 | No migration shipped ahead of its deploy adds a trigger/constraint that rejects a value the currently running release can write | Critical |
| MBC.2 | Every rejecting trigger/constraint/drop sits in a migration numbered after the release that stopped writing the old shape, with the gate written in its header and in a ruling | Critical |
| MBC.3 | A test applies the live migration set, writes the previous release's values, and passes; it fails against the previous (pre-fix) set | High |
| MBC.4 | A test loads the previous release's backup (schema and rows) into the post-migration schema | High |
| MBC.5 | A lossy remap keeps the pre-image; an applied migration is not edited | Medium |

## Verify

- `sqlite_master` of the migrated database has no trigger that `RAISE(ABORT)` on a value class the old code still emits.
- Run the previous release's write path against the migrated database (or its tests against the new schema).
- Restore yesterday's backup into a fresh database built from the migrations.
