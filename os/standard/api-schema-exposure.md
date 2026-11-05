# api-schema-exposure — a self-describing endpoint hands out the whole map

tags: [BOTH]
sources: reel lens pack `audit/lenses/reel-lenses-2026-09.md` L24 (`DdbnwpOiEZJ`, `@mattmurphyai`,
watched 2026-09-22)

## What "solid" looks like

No production endpoint answers a request for its own schema, metadata, or documentation UI
with an unauthenticated 200. A GraphQL API disables introspection outside development. An
OpenAPI/Swagger definition, if generated, is not reachable at a public path in prod. No
`GraphiQL`/Swagger-UI/Playground console ships to production. Build artifacts don't leave
source maps for API/server code reachable over HTTP.

## 1. Why this is not the same finding as `rsc-payload-exposure`

Lens 33 (`rsc-payload-exposure`) grades **over-broad row data** crossing a server→client
serialization boundary — the query returns twenty columns, the component renders three, and
the extra seventeen ride along in the RSC payload. That is a data-shape leak through a
rendering pipeline that was never trying to describe itself.

This lens grades a different attacker action against a different surface: a **self-describing
endpoint** — GraphQL introspection, a public OpenAPI/Swagger JSON, an admin GraphiQL/Playground
console, or an exposed `.map` file — that, by design, answers "what can this API do and what
does it look like." One request returns the complete schema: every query, mutation, type,
relationship, and (via error-message field suggestions) even typos toward names that were never
supposed to be guessable. No data row needs to leak for this to be a full reconnaissance win.

## 2. What to check

| # | Criterion | Solid (grade 2) | Gap detection | Severity |
|---|---|---|---|---|
| 1 | GraphQL introspection disabled in prod | `introspection: false` (or the framework's env-gated equivalent) in the production server config | `grep -rniE "introspection" apps/api/src --include=*.ts`; a config with introspection unconditionally `true`, or gated only by a client header rather than server env, is the finding | Critical |
| 2 | Query depth/complexity limited | A depth-limit or cost-analysis rule rejects deeply nested/expensive queries before execution | grep the GraphQL server setup for `depthLimit`/`costAnalysis`/`queryComplexity` middleware | High |
| 3 | Field suggestions disabled in prod errors | GraphQL error responses don't suggest field names ("did you mean `internalNotes`?") to an unauthenticated caller | grep server config for `validationRules`/`NoSchemaIntrospectionCustomRule`-equivalent, or confirm the library's default suggestion behavior is turned off in prod | Medium |
| 4 | No public Swagger/OpenAPI JSON or UI in prod | `/swagger.json`, `/openapi.json`, `/api-docs`, or a Swagger-UI/Redoc route is not reachable (401/404) in the production deployment, even if generated for internal use | `grep -rln "swagger-ui\|redoc\|apollo-server" apps/api/src --include=*.ts`; live check: `curl -s -o /dev/null -w "%{http_code}\n" "$API/api-docs"` / `"$API/swagger.json"` against the prod URL — 200 is the finding | High |
| 5 | No exposed source maps for server/API code | `.map` files for server-side bundles are not published to a public path | grep build/deploy config for a source-map upload step vs. a public static path; live check: request the `.js.map` implied by a served `.js` file's `//# sourceMappingURL` comment on an API/admin bundle | Medium |

Live GraphQL introspection probe (read-only, safe against a target you're authorized to test):

    curl -s "$API/graphql" -H 'content-type: application/json' \
      -d '{"query":"{__schema{types{name}}}"}'

A JSON body listing type names is the finding; a validation error or a 4xx is the pass.

## 3. What good looks like

Introspection, the Playground/GraphiQL console, and any generated Swagger UI are all present in
development and absent (401 or 404, not merely "unlinked") in production. Depth/complexity
limits reject a pathological query before it reaches a resolver. Error responses name nothing
the caller didn't already know.

## 4. Where it is graded

Any repo exposing GraphQL, or generating an OpenAPI/Swagger definition, or shipping a
server-side bundle with source maps. Not applicable to a REST-only API with no
schema-generation tooling and no server source maps published.
