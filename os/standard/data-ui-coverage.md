# data-ui-coverage — Data ↔ UI Coverage Rubric

tags: [BOTH]
sources: PLAYBOOK §3.7 (every-data-needs-a-UI), §14 (audit fleet: UI-coverage, Admin-endpoint-connection, Redundancy/consolidation), reference-iceberg-audit.md (term 15: CRUD logic)

## What "solid" looks like
Every table whose rows mean something to a human has a viewer (backend-only data with no UI is a defect); every admin UI action maps to a working endpoint (no dead buttons / 404s); no setting is editable in two places and no orphaned pages exist; pure infra tables are the only exemption.

## Criteria
| # | Criterion | Solid (grade 2) | Gap detection | Severity |
|---|---|---|---|---|
| 1 | Every meaningful table has a viewer | Every Prisma `model` whose rows mean something to a human has a UI page/component that reads it | List `model ` names in `schema.prisma`; for each, grep the frontend for a reference to that model's API route or query; any non-infra model with zero UI reference is a gap | High |
| 2 | Infra-only tables correctly exempt | Only pure infra tables (`_prisma_migrations`, rate counters) lack a viewer; nothing human-meaningful hides behind that exemption | grep `schema.prisma` for models matching `_prisma_migrations`/rate-counter/lock shapes; confirm every model WITHOUT a viewer is on that infra list | Medium |
| 3 | Admin UI action maps to a working endpoint | Every button/form submit handler calls an API route that exists | grep frontend handlers for `api.`/`fetch(`/`axios` call paths; for each path grep the backend router files for a matching route definition; any UI call with no backend route is a dead button | High |
| 4 | No orphaned pages | No page/route exists that nothing links to and nothing renders | List page route files (`app/**/page.tsx` / route components); grep the codebase for links/imports to each route; a page with zero inbound link/import reference is orphaned | Medium |
| 5 | No redundant edit surfaces | A given setting is editable in exactly one place (no social-links / announcement / hero split-brain) | grep for the same setting key (e.g. a layout/settings field name) appearing in 2+ distinct form/editor components; same key in multiple PUT/PATCH bodies = split-brain | Medium |
| 6 | CRUD completeness per viewer | Each human-meaningful table's UI exposes the create/read/update/delete operations its rows need | For each model with a viewer, grep the backend router for the route verbs (GET/POST/PUT/PATCH/DELETE) on that resource; a viewer with read-only routes for an editable table is a gap | Medium |
| 7 | Coverage enforced at plan + PR time | A documented gate requires new tables to ship with a viewer and new admin actions to map to an endpoint | grep `docs/`/PR-template/`*.md` for an every-data-needs-a-UI or UI-coverage / admin-endpoint-connection checklist item | Medium |

| 8 | Tenant delete cascades to object storage | Every tenant/account hard-delete purges the tenant-namespaced storage prefix (paginated deleteByPrefix), best-effort AFTER the DB commit, prefix-guarded (trailing slash, never bucket-wide) — object storage has no FK cascade | grep each hard-delete service path for an object-storage purge; namespaced uploads + no purge = gap | High |
| 9 | CSV import record-splitter is quote-aware | Any CSV import parses RECORDS quote-aware (handles `""` + embedded CRLF), never naive `split('\n')` (the record splitter and the field parser are two layers); validated by running a REAL customer file end-to-end, not synthetic fixtures | grep import paths for `split('\n')`/`split(/\r?\n/)` on raw CSV before a quote-aware splitter | Medium |

## Save-integrity sub-lens (added 2026-06-09 — from the a previous storefront product admin deep audit)
Coverage isn't enough — a wired form that silently fails to persist is worse than a missing one. Add these to every audit:
| # | Criterion | Solid (grade 2) | Gap detection | Severity |
|---|---|---|---|---|
| S1 | Schema↔UI enum parity | Every server `z.enum` is a superset of its UI `<select>` options | diff each `z.enum([...])` against the option list rendered into the matching control; a UI value the schema rejects = silent save-fail | **Critical** |
| S2 | Date-input vs `.datetime()` | No `type="date"` value reaches a `.datetime()` schema unconverted | grep `type="date"`; trace its field to the submit payload; if the Zod field is `.datetime()` and no ISO coercion exists → 422 | High |
| S3 | Masked-secret round-trip | Secret fields never return the full value from GET, and treat the mask sentinel as "unchanged" on save | grep secret fields (token/key/password/apiKey/appSid); confirm GET masks + save skips the mask value | High |
| S4 | Save errors are surfaced | Every mutation handler toasts/raises on non-2xx (no optimistic success swallowing failures) | grep save handlers for `.then` without an error branch / `catch` that only `console.error`s | High |
| S5 | Create == Edit field parity | A create form persists every field its edit form does (no create-time drops) | for each resource, diff fields in the POST body vs PUT body and vs the create-form vs edit-form | High |
| S6 | No unbounded list / page fan-out | List reads have `take`/cursor; no client `Promise.all` over page count | grep `findMany` without `take`; grep client code building `Promise.all` from a `totalPages` loop | High |

## Evidence (filled during audit, per repo)
- Audit scores from the predecessor admin deep audit moved to [incidents](../../docs/history/standards/incidents.md).
- an earlier messaging product: … (run same sub-lens next sweep)
