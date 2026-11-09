# 22 · Error-surface containment

**Concern:** what a user sees when something breaks, versus what you record.

`security.md` covers injection and secrets; `observability.md` covers Sentry and log retention. Neither owns the specific failure where an unhandled error **renders internals to the person who triggered it** — connection strings, framework versions, file paths, the failing line.

An AI-generated handler typically does one job for both audiences: it catches the error and returns it. That is a security hole shaped like a feature.

## The two-layer rule

Every error path has exactly two outputs:

- **Public** — a stable, human message plus a correlation id. No stack, no driver text, no SQL, no env values, no internal hostnames or paths.
- **Private** — the full technical record, server-side only, searchable, tied to that same correlation id.

If one object is being sent to both, the layer is not split.

## Grading criteria

| # | Criterion | Severity |
|---|---|---|
| 22.1 | A single error middleware owns the public response shape; no route hand-rolls its own error body | Critical |
| 22.2 | Public error bodies never include stack traces, driver messages, ORM error text, SQL, file paths, or env values — in **any** environment reachable by a user, including preview | Critical |
| 22.3 | A correlation id is returned publicly and logged privately, so support can join them without exposing internals | High |
| 22.4 | Errors are caught at **every** boundary, not just HTTP routes: background jobs, queue consumers, webhook receivers, payment callbacks, cron, and scheduled scripts | Critical |
| 22.5 | 4xx vs 5xx is honest — validation failures are not returned as 500 with a stack, and unexpected failures are not swallowed into a 200 | High |
| 22.6 | Structured logs redact PII and secrets at the logger, not at each call site | Critical |
| 22.7 | A test asserts the public shape of a deliberately-thrown internal error, so a regression is caught by CI rather than by a customer | High |
| 22.8 | The private pipeline captures timestamp, route, actor/session, inputs (redacted), and stack — enough to trace an incident without reproducing it | High |

## Traps

**"Every boundary" is the part that rots.** HTTP routes get an error middleware on day one. The surfaces added later — an Inngest function, a new webhook receiver, a payment callback, a cron sweep — each re-open the hole. Audit by enumerating *entry points*, not by reading the middleware.

**Fail-soft is not the same as handled.** A `catch` that returns `[]` or `null` hides a wrong endpoint or a broken query behind a plausible empty state. Log loudly, then degrade.

**A substituted artifact is worse than an empty one.** The dangerous fail-soft does not return nothing — it returns *something plausible but from the wrong source*, labelled as if it were what you asked for. An empty result gets investigated; a populated wrong one gets used. Measured case: `opensrc path <pkg>@<version>` resolves upstream tags as `v<version>` only, misses the `<pkg>@<version>` form that monorepos publish, silently clones the **default branch**, and caches it under a directory named with the version you requested — then prints that path with **no warning and exit 0**. `@opennextjs/cloudflare@1.19.11` yielded 1.20.2; `@upstash/redis@1.34.0` yielded 1.30.2; `@prisma/client@6.19.3` yielded 0.0.0. An agent reading that source then describes behaviour that is not in the build. Rule: any resolver that maps a requested identity to a fetched artifact must **prove provenance or exit non-zero** — never fall back to a default and never encode the request into the cache path as if it were the result. `ops/srcof.sh` is the corrected implementation (npm `gitHead`, else a tag verified present via `git ls-remote`, else fail loud). Note the corollary: validate by *provenance*, not by re-reading the artifact's own version field — monorepos do not bump in-tree at tag time, so a correct checkout can legitimately carry a different `package.json` version.
`sources: reference-package-source-fetch-srcof, feedback-failsoft-helper-hides-wrong-endpoint`

**A per-item failure must not set a global flag**, and a global catch must not mark every item failed. Both invert the truth of what happened.

**Swallowed errors defeat their own tests.** A `try/catch` around an assertion turns a failing test green.

**Preview/staging counts as reachable.** Verbose errors "only in non-prod" still leak whenever a preview URL is shared or indexed.

## Verify

Trigger a real internal failure (bad DB credential, forced throw) against each boundary class and read the raw HTTP body — do not infer from the code. Confirm the private record for the same correlation id exists and is complete.
