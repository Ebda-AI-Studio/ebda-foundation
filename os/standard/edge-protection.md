# 24 · Edge protection & abuse resistance

**Concern:** staying up when someone points a loop at you.

`cache-ratelimit.md` covers per-endpoint Redis rate limiting — necessary, and not sufficient. Application-layer limiting still requires the request to reach the application. Volumetric abuse has to be absorbed *before* the origin, and the response to an incident has to be written down before the incident.

## Grading criteria

| # | Criterion | Severity |
|---|---|---|
| 24.1 | A WAF sits in front of the whole stack, not only the marketing site — API and admin origins included | Critical |
| 24.2 | Origin hosts are not directly reachable, bypassing the edge (no naked origin hostname/IP serving traffic) | Critical |
| 24.3 | Rate limiting is **adaptive** — escalating throttle → challenge → temporary ban based on behaviour (frequency, origin diversity, path mix), not a single fixed cap | High |
| 24.4 | Expensive endpoints (AI generation, export, search, image processing) carry their own tighter limits and a cost cap | Critical |
| 24.5 | Bot/automation rules cover credential-stuffing on auth and enumeration on public id-bearing routes | High |
| 24.6 | A written DDoS/abuse playbook exists: who is paged, what gets toggled (under-attack mode, cached-only, feature kill-switches), where traffic is shed | High |
| 24.7 | The playbook's toggles are known-working — exercised at least once, not discovered live | Medium |
| 24.8 | Rate-limit state is shared across replicas (Redis-backed), so limits are not per-instance | High |

## Traps

**Being on a CDN is not being protected.** A CDN in front of the storefront while the API answers on a separate origin hostname leaves the expensive half exposed. Enumerate every public hostname and check each.

**Fixed caps do not describe attacks.** "5 per 15 minutes per IP" stops one noisy client and nothing distributed. Escalation on behaviour is the difference.

**The AI-cost endpoints are the real target.** An unauthenticated or weakly-capped generation endpoint is a direct debit from your margin (see `unit-economics.md`) long before it is an availability problem.

**A playbook nobody has run is a document, not a plan.** Know in advance which switch sheds load without breaking checkout.

## Verify

From outside the edge, confirm the origin hostnames do not answer directly. Drive a burst against a representative endpoint and observe escalation (not just a flat 429 wall). Confirm limit counters are shared across replicas.
