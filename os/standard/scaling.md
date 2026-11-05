# scaling — Vertical & Horizontal Scaling Rubric

tags: [BOTH]
sources: PLAYBOOK §4 (vertical + horizontal scaling), PLAYBOOK §3.5 (caching + rate-limiting replica-safe), CLAUDE.md (rule 3 scaling-from-day-1), reference-iceberg-audit.md (scaling-cliff term), reference-force-ai-production-grade-standard.md (layer 6: scaling/perf)

## What "solid" looks like
Vertical sliders set to sane production values and validated against real RSS; horizontal replicas only after the code prerequisites are met — Socket.io on the Redis adapter, every recurring timer behind a Redis leader-election lock, Redis-backed rate limit + shared cache + pooled DB — with a Redis-absent fallback so single-instance dev still runs; reads built scaling-from-day-1 (explicit `select`, indexed WHERE/ORDER BY, cursor pagination + hard take cap, edge cache + tag invalidation); slow work offloaded to Inngest; a k6 load test with a documented p95 ceiling; and a `docs/SCALING.md` capturing the prereqs checklist + what to watch after scaling.

## Criteria
| # | Criterion | Solid (grade 2) | Gap detection | Severity |
|---|---|---|---|---|
| 1 | Vertical sliders validated against real RSS | Production CPU/RAM values set; `/health` reports `process.memoryUsage().rss` so the slider is sized against real usage | grep health route for `memoryUsage`/`rss`; confirm a `/health` endpoint exists | Medium |
| 2 | Socket.io Redis adapter before >1 replica | Socket.io wired to `@socket.io/redis-adapter` (with in-process fallback when Redis absent) | grep for `socket.io` usage; if present, grep for `@socket.io/redis-adapter`/`createAdapter` — missing while replicas>1 is the gap | Critical |
| 3 | Cron leader-election on recurring timers | Every module-level `setInterval`/recurring timer gated by a Redis lock (`SET key val NX PX ttl`); Inngest crons + atomic-`RPOP` workers exempt | grep for `setInterval(`/`setTimeout(`/cron schedules; for each non-Inngest one confirm a `NX`/`PX` Redis-lock guard wraps it | Critical |
| 4 | Redis-backed rate limit (shared across instances) | `rate-limit-redis` (or equivalent Redis store) so limits are shared, not in-process | grep rate-limit middleware for a Redis store (`rate-limit-redis`/`RedisStore`); an in-process/memory store is the gap | High |
| 5 | Shared cache + pooled DB | Cache lives in Redis (not per-process memory); Prisma uses the pooled Neon URL | grep for the cache client (Redis) vs an in-memory `Map` cache; grep datasource/env for a pooled (`-pooler`/`pgbouncer`) `DATABASE_URL` | High |
| 6 | Redis-absent single-instance fallback | Adapter + leader-election degrade to in-process adapter + "this instance is leader" when Redis is unavailable, so local dev runs everything | grep adapter/leader-election setup for a Redis-absent branch (fallback to in-process / forced-leader) | Medium |
| 7 | Cursor pagination + hard take cap | List endpoints use cursor pagination with a hard `take` ceiling, not unbounded `findMany` | grep Prisma `findMany` calls lacking `take:`; grep for offset/`skip:` pagination on large tables (offset is the gap) | High |
| 8 | Explicit select + indexed WHERE/ORDER BY | Queries name an explicit `select`; columns used in WHERE/ORDER BY are indexed in the schema | grep hot `findMany`/`findFirst` for missing `select:`; cross-check WHERE/ORDER BY columns against `@@index`/`@index` in `schema.prisma` | Medium |
| 9 | Edge cache + tag invalidation | Cacheable reads use edge cache with tag-based invalidation on writes | grep for the cache tag API (`cacheTag`/`revalidateTag`/`unstable_cache` tags) on read paths and matching invalidation on writes | Medium |
| 10 | Slow work offloaded to async jobs | Anything >300ms or 3rd-party runs via Inngest/BullMQ, not inline in the request | grep route handlers for synchronous slow/3rd-party calls; confirm an Inngest/BullMQ dispatch instead of inline `await` | High |
| 11 | k6 load test with documented p95 ceiling | A k6 script exists and runs (not disabled) with a documented p95 threshold; p95 >500ms fixed before ship | file-exists check for a k6 script (`*.k6.js`/`k6/`); grep for a `p95`/`http_req_duration` threshold; confirm it's not `continue-on-error`/disabled | High |
| 12 | docs/SCALING.md prereqs + watch list | `docs/SCALING.md` documents the horizontal prereqs checklist, dashboard steps, and post-scale watch items (DB connection count vs pool limit, Redis memory) | file-exists check for `docs/SCALING.md`; grep it for the prereqs checklist + "connection"/"pool"/"Redis memory" watch items | Medium |

## Evidence (filled during audit, per repo)
- FWB: …
- WBS: …
