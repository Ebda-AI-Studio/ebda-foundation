# rls — Multi-Tenant Row-Level Security Rubric

tags: [BOTH]
sources: PLAYBOOK §3.2 (multi-tenant RLS), §3 (table H10.4 GUC, §10.4 snapshot re-verify, §11 local-points-at-scratch-DB, §16 production-ready checklist), CLAUDE.md (RLS-readiness note in feedback-ai-pr-reviewer-and-security-hardening), reference-iceberg-audit.md (term: multi-tenant isolation), reference-force-ai-production-grade-standard.md (layer 3: data layer — RLS GUC)

## What "solid" looks like
RLS plus `FORCE ROW LEVEL SECURITY` on every tenant-scoped table; the app connects as a NON-owner role (not the `rolbypassrls` owner) so policies are actually exercised; tenant context is set per-request via a GUC (`app.current_store_id`); cross-tenant access goes through ONE named bypass helper on super-admin-guarded routes only; the policy shape (allow-all-when-unset vs block-when-unset) is standardized and known per table class; and before the owner→app-role cutover every super-admin handler and every job has been swept and classified.

## Criteria
| # | Criterion | Solid (grade 2) | Gap detection | Severity |
|---|---|---|---|---|
| 1 | RLS + FORCE on every tenant table | Every tenant-scoped table has both `ENABLE ROW LEVEL SECURITY` and `FORCE ROW LEVEL SECURITY` | grep migrations/SQL for `ENABLE ROW LEVEL SECURITY` with no matching `FORCE ROW LEVEL SECURITY`; list tenant tables lacking either | Critical |
| 2 | App connects as non-owner role | Runtime connection string uses a non-owner role (e.g. `force_app`), NOT the `neondb_owner`/owner role that has `rolbypassrls` | grep runtime `DATABASE_URL`/connection config for `neondb_owner` or the owner role; SQL `SELECT rolname,rolbypassrls FROM pg_roles` — app role must be `rolbypassrls=false` | Critical |
| 3 | Per-request tenant GUC | Middleware (AsyncLocalStorage) sets `app.current_store_id` via `set_config`/`current_setting` on every tenant-scoped request | grep for `app.current_store_id` + `set_config`/`current_setting`; confirm a request middleware sets it, not per-query ad hoc | Critical |
| 4 | Standardized policy shape, known per table class | One policy shape per table class, with its unset-GUC behavior documented (IS NULL-escape = allow-all-when-unset vs no-escape = block-when-unset) | grep policy DDL (`CREATE POLICY`) for `current_store_id() IS NULL OR` vs `store_id = current_setting(...)`; flag tables mixing both shapes | High |
| 5 | Single named bypass helper, super-admin only | `withRlsBypass` (sets `app.bypass_rls='true'`) is the ONLY cross-tenant path, called only inside `authorize('super_admin')`-guarded handlers | grep for `withRlsBypass`/`app.bypass_rls`; flag any call site not behind a super-admin authorize guard | Critical |
| 6 | Tenant-context helper distinct from bypass | `runInTenantContext(storeId, fn)` (sets `app.current_store_id`) exists and is used for single-store work outside request middleware, never conflated with bypass | grep for `runInTenantContext`; confirm it is a separate symbol from the bypass helper and sets `current_store_id` (not `bypass_rls`) | High |
| 7 | Owner→app-role cutover sweep done | Before cutover, every `authorize('super_admin')` handler + every job/cron DB access classified (cross-tenant→bypass / single-store→tenant-context / behind-middleware→leave) | grep for `authorize('super_admin')` handlers and Inngest/cron jobs; each DB access must be wrapped in bypass or tenant-context (jobs have no request → no GUC) | Critical |
| 8 | Local dev points at a scratch DB, not prod-as-owner | Local `.env` `DATABASE_URL` points at a scratch/preview branch as the app role, never prod as owner (else RLS is never exercised) | grep `.env`/`.env.local` `DATABASE_URL` host for the prod host and/or owner role; verify host before any `migrate`/`db push` | High |
| 9 | RLS re-verified after snapshot restore | Runbook step re-verifies RLS policy state after any snapshot/DR restore (runtime depends on policy shape) | file/grep DR runbook (`docs/ROLLBACK.md`/runbooks) for a post-restore "re-verify RLS policy state" step | Medium |
| 10 | Tenant isolation has a verifying test | An automated test exercises the policy as the app role (a cross-tenant read returns empty / is blocked) — app-layer `where:{store_id}` alone is NOT FORCE-RLS-ready | grep tests for an RLS/cross-tenant isolation test setting the GUC then asserting isolation; absence = gap | High |
| 11 | Policy per command run | Every RLS-enabled table has a policy for EACH command the app runs (INSERT/UPDATE/DELETE, not just SELECT), each honoring the bypass GUC + tenant scope — `ENABLE RLS` + only a SELECT policy silently denies all writes (42501) even via withRlsBypass | `SELECT cmd FROM pg_policies` per RLS table; flag any table with writes-in-code but no INSERT/UPDATE/DELETE policy | Critical |
| 12 | Pre-auth + own-row reads bypass-wrapped | `/login` `/refresh` `/forgot` and `/me`-family own-row reads of a policed table run under withRlsBypass (no tenant GUC exists pre-auth; admins have null tenant id) — a 401 on a policed-table login means RLS-empty, not a bad password | grep auth + self-service routes for reads of an RLS table not wrapped in bypass | Critical |

## Evidence (filled during audit, per repo)
- FWB: …
- WBS: …
