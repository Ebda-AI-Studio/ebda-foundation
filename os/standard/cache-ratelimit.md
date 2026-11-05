# cache-ratelimit — Caching & Rate-Limiting Rubric

tags: [BOTH]
sources: PLAYBOOK §3.5 (caching + rate-limiting replica-safe), §3 architecture table (Cache/Real-time rows), §4 (horizontal scaling prerequisites), §16 (production-ready checklist), reference-force-ai-production-grade-standard.md (API & validation: 429+Retry-After), reference-iceberg-audit.md (term 22: rate limiting)

## What "solid" looks like
Rate limiting is Redis-backed so limits are shared across every instance; caching is two-tier (Redis → in-memory bounded map → CDN s-maxage) with tag invalidation and a TTL floor ≥120s; sub-2-minute needs go to the in-memory bounded map, not Redis; every public, auth, and expensive endpoint is limited and returns 429 + Retry-After; and the system is replica-safe by design (or explicitly single-instance-by-design and documented).

## Criteria
| # | Criterion | Solid (grade 2) | Gap detection | Severity |
|---|---|---|---|---|
| 1 | Redis-backed rate limiting | Limiter uses `rate-limit-redis` (or equivalent shared store) so limits are shared across instances | grep rate-limit setup for `rate-limit-redis`/`RedisStore`; flag in-process/`MemoryStore` limiters (meaningless with >1 replica) | Critical |
| 2 | Every public/auth/expensive endpoint limited | Each public, auth, and expensive route has a rate-limit middleware applied | grep route files for limiter middleware on public/auth/expensive handlers; list such routes with no limiter attached | High |
| 3 | 429 + Retry-After on limit | Rate-limited responses return HTTP 429 with a `Retry-After` header | grep limiter/error handler for `429` and `Retry-After`/`retryAfter` | Medium |
| 4 | Two-tier cache with tag invalidation | Cache is Redis → in-memory bounded map → CDN `s-maxage`, with tag-based invalidation | grep cache layer for both a Redis client and an invalidation-by-tag call (`invalidateTag`/tag-keyed delete); flag single-tier-only caches | High |
| 5 | TTL floor ≥120s | Cache entry TTLs are ≥120s to protect DB compute on cache-miss | grep cache `set`/TTL config for TTL values; flag any TTL below 120s on Redis-cached keys | Medium |
| 6 | Sub-2-min needs use in-memory bounded map | Needs under 2 minutes go to a bounded in-memory map (not Redis); the map is size-bounded | grep for a bounded in-memory cache (LRU/max-size map) for short-TTL data; flag unbounded module-level `Map`/object caches | Medium |
| 7 | CDN edge cache via s-maxage | Cacheable responses set `s-maxage` for the CDN tier | grep response headers/cache config for `s-maxage`/`Cache-Control` on cacheable routes | Medium |
| 8 | Replica-safe or documented single-instance | Redis rate-limit + shared cache + pooled DB in place so >1 replica is correct; OR explicitly single-instance-by-design and documented | grep `docs/SCALING.md` for the replica prerequisites checklist (Redis rate-limit + shared cache) OR an explicit single-instance-by-design statement | High |
| 9 | Redis-absent fallback | A Redis-absent fallback (in-process limiter/cache) exists so single-instance local dev still runs | grep cache/rate-limit init for a no-Redis branch/fallback path | Medium |
| 10 | Redis/Upstash access-controlled, not a default-open connection | The store requires auth (never a default/no-password connection), an ACL restricts the app's credential to the command set it actually uses (no `FLUSHALL`/`CONFIG` from the app role), and network access is bound to the deployment's IP range or a private network rather than `0.0.0.0/0` — because when the cache holds sessions or tokens, an open connection is a way to become any user without cracking a single password | `grep -rniE "REDIS_URL\|UPSTASH_REDIS_REST" apps/*/.env.example apps/*/src/**/redis*.ts 2>/dev/null` to locate the client; then check the provider dashboard/IaC for TLS + ACL + network restriction — this is infra config, not always visible in a grep, so the check locates the client and the read is against the instance's actual settings | Critical |

## Evidence (filled during audit, per repo)
- FWB: …
- WBS: …
