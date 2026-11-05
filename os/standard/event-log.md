# event-log — Append-Only Event Log Rubric

tags: [BOTH]
sources: PLAYBOOK §3.4 (append-only `<entity>_events`), §3.3 (idempotency/SAVEPOINT), §13 (Event-log / mutate-in-place review), §16 (production-ready checklist), reference-iceberg-audit.md (term 6: Data integrity)

## What "solid" looks like
Every business-critical state machine (payment, order, subscription, payout, loyalty tier) writes to an append-only `<entity>_events` table at every mutation, preserving the raw 3rd-party webhook payload. `entity.status` carries the current state; the events table records how it got there. Rows are insert-only — no UPDATE/DELETE mutates an event in place. For money/trust state this is non-negotiable: the log is the source of truth for auditability and dispute resolution.

## Criteria
| # | Criterion | Solid (grade 2) | Gap detection | Severity |
|---|---|---|---|---|
| 1 | Events table exists for each money/trust entity | An append-only `<entity>_events` table (payment/order/subscription/payout/loyalty) in the schema | grep `schema.prisma`/migrations for `model .*Event`/`_events` table; list money/trust entities lacking one | Critical |
| 2 | Event written at every mutation | Every status/state transition of the entity inserts an event row, not just some paths | grep services for `.status =`/`update({...status` on the entity and confirm a paired `events.create`; flag transitions with no event insert | Critical |
| 3 | Raw 3rd-party payload preserved | The event row stores the unmodified webhook/gateway payload (e.g. `rawPayload`/`payload Json`) | grep events model for a `Json`/`jsonb` payload column; grep webhook handlers for the raw body persisted before parsing | High |
| 4 | Append-only — no in-place mutation | Events are insert-only; no UPDATE/DELETE on event rows ("mutate-in-place" is the defect) | grep for `events.update(`/`events.delete(`/`UPDATE *_events`/`DELETE FROM *_events`; any hit is a violation | Critical |
| 5 | status = current state, events = history | `entity.status` reflects current state derived from / consistent with the latest event | grep entity model for a `status` field; confirm the log is separate from the status column (not status-only with no history) | High |
| 6 | Idempotent event writes | Webhook/gateway re-delivery does not create duplicate events or double-apply state; uses `SAVEPOINT` (not `create+catch(P2002)` inside a `$transaction`) | grep transactional money paths for `create` + `catch`/`P2002` inside `$transaction` (broken pattern); confirm `SAVEPOINT` or a unique idempotency key on the event | High |

## Evidence (filled during audit, per repo)
- a previous storefront product: …
- an earlier messaging product: …
