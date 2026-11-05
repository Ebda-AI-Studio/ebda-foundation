# Lens pack: AI-built app failure modes (2026-09)

18 lenses from 14 reels — 5 by `@-MM` (`#aidirectedengineering`, the same source as the
2026-08 pack) and 4 by `@haydenschmitty` (`#claudecode #vibecoding`); L16–L18 added 2026-09-19
from `@mattmurphyai` (`DdZDAYDkr3A`), `@murphmaxxing` (`DdUmUNPB_0g`) and `@alberta.tech`
(`DdRnkRpxNhC`). Each is a single claim about how an AI-built production system fails,
expressed as a check — except L18, whose claim was false and whose **verification** is the
lens.

Two further claims from these reels are **already graded** and are not repeated here:
wide-open CORS (2026-08 pack L10) and SSRF via a server-side fetch of a user-supplied URL
(L11). A tenth reel — `mirroir-mcp`, driving a real iPhone from Claude Code through macOS
iPhone Mirroring — is an OS tooling capability, not an audit lens; it is recorded in the
ideas note rather than here.

**How to use:** run the checks, then **read the code behind every hit before recording a
finding**. The checks locate candidates; they do not judge. On the first run of this pack
one candidate was discarded on inspection (see the fleet status), and a grep count
reported as a finding is how an audit manufactures false accusations —
`feedback-audit-findings-are-claims-not-facts`.

**Fleet status.** Applied to a storefront product (2026-09-04): 11 code-auditable,
**11 pass, 0 gaps**, 2 not applicable. L14-L15 applied (2026-09-10): **1 gap found and
fixed** (L14 — one `jwt.verify` of eight did not pin `algorithms`), L15 clean. Both now
ship as GATES in that repo (`tests/unit/jwt-verification-lens.test.ts`,
`tests/unit/raw-sql-escape-hatch-lens.test.ts`) rather than as a one-time result — see
`standard/closed-loop-audit.md` for why a finding without a rerun is half an audit. **Not yet applied** to the predecessor repos (see `docs/history/`) — run them there and record the result.

**Why this pack matters more than its pass rate.** L6 is the exact defect that produced a
P0 in a storefront product on 2026-09-03: a gateway refund on a cash-on-delivery order
refunded an arbitrary *other* order, because Prisma drops an `undefined` filter and the
`where` collapsed to empty. The lens was not derived from that incident — it arrived
independently from a reel — which is the argument for keeping packs: the same failure
mode is being described from the outside while it is being paid for on the inside.

---

## Security

**L1 — The URL is trusted instead of the session.** An endpoint loads a record by the id
in the path and never asks whether the caller owns it. Change the number, read someone
else's account. Sequential ids make it enumerable.
→ Every endpoint taking a record id verifies ownership against the session, and ids are
UUIDs rather than sequential.
`grep -rnE "params\.(id|userId|orderId|customerId)" apps/api/src/routes | head -40`
Then read each: a tenant scope, an ownership comparison, or an unguessable capability
token all count. A v4 uuid handed back to the creator moments earlier is a legitimate
guest model **if** it is documented and the row is confirmed ownerless.

**L2 — Server credentials shipped to the browser.** Server logic and client components in
one file; the bundler inlines the connection string into the client chunk.
→ `server-only` on modules holding secrets, server/client files separated, and a build
scan that greps the production bundle for credential shapes.
`grep -rn "server-only" apps/*/package.json` ·
`grep -rniE "process\.env\.(DATABASE_URL|.*_SECRET|.*_TOKEN)" apps/web/src apps/admin/src`
A CI job that scans the built client output is the gate; the package is the guard rail.

**L3 — The checkout price comes from the client.** The amount is posted from the
frontend; the server passes it to the payment provider without checking it against the
catalogue. Change it to one, and it is charged.
→ Line prices are read server-side from the product/variant row at order time. The
client's asserted price and total are never persisted or charged.
`grep -rnE "body\.(price|total|amount)|input\.price" apps/api/src/services apps/api/src/routes`

**L4 — The error page is the reconnaissance.** A broken link returns the database name,
the table, the ORM and the failing query, because development error handling shipped to
production.
→ Responses are shaped by environment; internals go to the log with a correlation id, and
the client gets a code and a message that names nothing.
`grep -rniE "err\.(stack|message)" apps/api/src/middleware/error-handler.ts`
Read the branches: the test is what reaches the *client*, not what is logged.

**L5 — The OAuth redirect is open.** A login link delivers the token to a server you have
never seen; the user believes they signed in.
→ Redirect URIs pinned to exact registered URLs, a `state` parameter enforced on every
request, token scopes minimised.
`grep -rniE "redirect_uri|oauth|state=" apps/api/src/routes/auth*.ts`
Not applicable to systems that mint their own sessions and integrate no external IdP.

**L6 — A dynamic ORM condition collapses to "match anything".** A filter built from an
optional value is dropped by the ORM when the value is `undefined`, so the `where` empties
and the query returns an arbitrary row instead of none.
→ Every query whose filter can receive an optional value either rejects the absent case
before querying, or constrains the column so absence cannot match.
`grep -rnE "findFirst|findUnique|updateMany|deleteMany" apps/api/src --include=*.ts -A6 | grep -nE "where: \{[^}]*\$\{?[a-zA-Z]+\??\}?"`
Prisma drops `undefined` keys entirely — an empty `where` is a full-table match, not a
no-match. This is the one that cost a real P0.

**L7 — The API returns more than the interface renders.** Endpoints select whole rows, so
fields the UI never shows — internal flags, cost prices, other people's identifiers — ship
to anyone who opens the network tab.
→ Explicit `select` on read paths, shaped to what the surface actually renders.
`grep -rn "findMany(" apps/api/src --include=*.ts -A4 | grep -c "select:"`
Compare against the total: a low ratio is the candidate, not the finding.

**L8 — Stored cross-site scripting.** User-supplied content is persisted and later
rendered as markup, so the payload executes for every subsequent viewer.
→ Inputs that end up in `href`, `src`, `dangerouslySetInnerHTML` or a template are
validated on write and escaped on read.
`grep -rn "dangerouslySetInnerHTML" apps/web/src apps/admin/src` ·
`grep -rniE "addressUrl|website|redirect|link" apps/api/src/routes/*.ts | grep -i "z\."`

## Performance and shape

**L9 — N+1 queries.** A list renders, and each row triggers its own query for a relation.
→ Relations are loaded with the parent (`include`/`select`), or batched.
`grep -rnE "for \(|\.map\(async" apps/api/src/services --include=*.ts -A4 | grep -nE "await prisma\."`

**L10 — Unpaginated reads.** An endpoint returns every row, so the page slows in
proportion to how successful the merchant is.
→ Every list endpoint takes a bounded limit, with a hard server-side cap the client
cannot raise.
`grep -rn "findMany(" apps/api/src/routes --include=*.ts -A6 | grep -c "take:"`

**L11 — Everything is synchronous.** Third-party calls, emails and image work happen
inside the request, so the user waits for work that did not need to block them.
→ Anything over a few hundred milliseconds, or calling a third party, is queued.
`grep -rnE "await (fetch|axios|sendEmail|resend)" apps/api/src/routes --include=*.ts`

**L12 — No connection pooler.** Every request opens and closes its own database
connection; connections are expensive and finite, so the ceiling arrives early.
→ A pooler in front of the database in transaction mode, with the app pointed at it.
`grep -rn "pooler\|pgbouncer\|connection_limit" packages/database docs/ENVIRONMENT.md`

## Interface

**L13 — Icon-only controls with no label.** A button is an icon, with no text and no
tooltip, so its meaning is guessable at best and invisible to a screen reader.
→ Every interactive control carries a visible label, an `aria-label`, or a tooltip.
`grep -rnE "<(button|IconButton)[^>]*>\s*<[A-Z]" apps/admin/src apps/web/src --include=*.tsx | head -40`
Then read them: an adjacent `<span className="sr-only">` or `aria-label` counts.

## Security (added 2026-09-10)

**L14 — The claims are read without checking the envelope was sealed.** The auth layer
DECODES a JWT to read `role` and never VERIFIES the signature. A user base64-decodes their
own token, flips `member` to `admin`, re-encodes, and the server grants every protected
route — no alert, no log line. The same shortcut skips `exp` (a stolen token then works
forever) and `iss` (a token minted by a different tenant of the same auth provider is
accepted). It survives review because it works perfectly for honest users; only a
deliberately modified token reveals the authorization layer is absent.
→ Signature verified before ANY claim is read; `exp`, `iss` and `aud` all checked;
`algorithms` pinned; the provider's server-side SDK preferred over hand-rolled parsing,
because it also handles key rotation.
`grep -rn "jwt.decode\|jwtDecode\|decodeJwt\|atob(" apps --include=*.ts | grep -v test`
`grep -rn -A6 "jwt.verify" apps/api/src --include=*.ts | grep -v test | grep -c algorithms`
Then read each: `decode` AFTER a successful `verify` (re-extracting `jti` cheaply) is
correct and common — the question is only whether a verify precedes it. Compare the
`decode` count against the `verify` count; a decode with no verify in the same function is
the finding. `ignoreExpiration: true` is defensible ONLY where the call establishes
identity and never authorises, and it must say so in place.

**L15 — The ORM protected you; the escape hatch does not.** The AI needs a join or a
search the query builder cannot express, drops to raw SQL, and every protection the ORM
provided disappears at that line. A crafted string in a search field, a filter, or a SORT
PARAMETER reaches the database as command rather than as data.
→ Raw queries use the ORM's PARAMETERISED form; any identifier that must be interpolated
(a column name, a savepoint, a `SET LOCAL`) comes from a closed allowlist of literals,
never caller text; every input is constrained by type and length BEFORE the query, and
unexpected input is REJECTED rather than sanitised.
`grep -rn --include=*.ts -F -e queryRawUnsafe -e executeRawUnsafe apps packages | grep -v node_modules`
`grep -rn --include=*.ts -F 'Prisma.raw(' apps packages | grep -v node_modules`
Prisma has three shapes and only two are obvious: `` $queryRaw`...${v}...` `` is
PARAMETERISED; `` $queryRawUnsafe(`...${v}`) `` is a built string; and `Prisma.raw(v)`
injects verbatim **inside** a tagged template that parameterises everything else — the
third is the one that hides. Postgres cannot bind a parameter in `SAVEPOINT` or
`SET LOCAL`, so those legitimately interpolate; the question is whether the value is
generated internally or validated first. A sort parameter mapped through a ternary to
fixed column literals is a pass; `options.sortBy || 'default'` reaching `Prisma.raw` is
the finding.

## Payload exposure (added 2026-09-19)

*(`@mattmurphyai`, reel `DdZDAYDkr3A`, 2:23, watched 2026-09-19.)*

**L16 — The UI is the window; the payload is the wall behind it.** A server component queries
the database and passes the row to the components that render it. The page shows a name, an
email and a photo; the payload carries all twenty columns, password hash and billing token
included, because React serialises every prop that crosses into a client component into the RSC
wire format and the browser parses it. Nested children inherit the parent's object, so one
over-broad prop at the top exposes data to every child — and a list page multiplies it: twenty
rows is twenty full records, once per visitor. The payload is structured, not HTML, so reading
it is a parse rather than a scrape.
→ Every query feeding a rendered component names an explicit `select` of the fields that
component renders, and each server→client boundary passes a projection (a DTO), never the row.
`grep -rln '"use client"' src app --include=*.tsx`
`grep -rnE "<[A-Z][A-Za-z]+[^>]*(user|row|record|data|profile|customer|order)=\{[a-zA-Z]" src app --include=*.tsx | head -40`
Then read: follow every prop on a client component back to its query. A projection built
server-side (an id, a label, a count) is a pass; the ORM row, or `{...row}`, is the finding.
**The boundary decides, not the query** — a row rendered by a *server* component reaches the
browser as text, while the same row handed to a client component travels in full, read or not.
This is not `scaling`'s explicit-`select` criterion: that one grades index use and row size, and
it passes happily while shipping a password hash to the browser.

## Money & account survival (added 2026-09-19)

*(`@murphmaxxing`, reel `DdUmUNPB_0g`, 0:56, watched 2026-09-19.)*

**L17 — The processor reads your site before it pays you.** `money` grades the payment path;
all of it can be correct while the account receiving the money is suspended. Payouts are held
at activation while a reviewer looks for refund and cancellation terms and a visible way to
reach a human. Then the ratio: the threshold is a percentage, so the small merchant is the
exposed one — at ~200 transactions a month **two** chargebacks is 1%, past the common 0.75%
review line, and the two cheapest causes are a statement descriptor the cardholder does not
recognise and a charge they did not expect. Then the evidence: a dispute is decided on
documents, and explicit usage terms — what a unit buys, what expires, what renews — are what
gets submitted.
→ Before the first live charge: refund/cancellation/privacy terms reachable from the paying
surface, a support contact on the site itself, a recognisable statement descriptor, overage and
renewal stated before the charge, and the ToS naming the unit sold.
`for p in /terms /refund /privacy /support; do curl -s -o /dev/null -w "$p %{http_code}\n" "$SITE$p"; done`
`curl -s "$SITE/<paying-page>" | grep -oE 'mailto:[^"<]+'`
A **merchant of record** (Polar, Paddle, Lemon Squeezy) changes what is covered, not whether the
lens applies: the MoR owns the card relationship and hosts its own terms, which covers the
liability half — but its reviewer still reads your site, and a buyer who cannot find you emails
the MoR instead.

## Agent & product configuration (added 2026-09-19)

*(`@alberta.tech`, reel `DdRnkRpxNhC`, 0:25, watched 2026-09-19 — claim checked and REJECTED.)*

**L18 — The model id in shipped config is a fact with a decay date.** *(The claim as it arrived
was false, and the verification is the lens.)* The reel described an open-source AI product as
defaulting to Claude Sonnet 3.5. The repository says `claude-sonnet-5` default, `claude-opus-5`
deep reasoning, `claude-haiku-4-5` for background extraction; its licence reports `NOASSERTION`
where the video's badge showed Apache-2.0 (`SenteLabsAI/OpenExecutive`, read 2026-09-19). What
survives is the first-party rule: a versioned model id decays silently, and the failure lands at
runtime inside a request a user is waiting on. The quieter half is a stale id that still
resolves — the product keeps working, on a model two generations behind, and nothing ever
raises.
→ Model ids resolve from one place per product, prefer the vendor's moving alias, and any
versioned pin carries a dated reason; the vendor's current list confirms it, never memory.
`grep -rnE "claude-[a-z0-9.-]+|gpt-[a-z0-9.-]+|gemini-[a-z0-9.-]+|us\.anthropic\." --include=*.ts --include=*.tsx --include=*.py --include=*.md . | grep -v node_modules | head -40`
Then read: count distinct sources; more than one is the finding. `skill-hygiene` grades the same
decay inside an installed skill — this grades the id the running product sends to the provider.

**Fleet status for L16–L18.** Applied to `mypovonai-learn` 2026-09-19:
**L16 PASS** (every client component receives primitives — `locale`, slugs, `signedIn`, article
metadata; audit rows are rendered by *server* components and are already a projection whose
`targetRef` is an 8-char hash, never the raw target);
**L17 GAP** (`/terms`, `/refund`, `/privacy`, `/support` all 404, no `mailto:` on five key pages,
no policy URL in the sitemap — on the site that sells token packs; Polar-as-MoR covers the
liability half only);
**L18 PASS, one note** — the Worker calls no hosted model (judging runs on the customer's own
seat), and the CLI's one pin is a single source with a moving family id and an env override:
`fleet/transports.mjs:21`, `const DEFAULT_MODEL = process.env.FLEET_MODEL ?? "claude-sonnet-5"`.
The note is criterion 4: a rejected model surfaces as `anthropic <status>: <body>`, which names
the provider's complaint but not `FLEET_MODEL`, the key that chose it.

**Not yet applied** to the predecessor repos (see `docs/history/`).

## Second batch (added 2026-09-22)

9 reels, all by `@mattmurphyai` (Matt Murphy). **Provenance note:** transcription of the audio
was unavailable for this batch; the claims below are captured **verbatim from the reels' own
captions**, which read as Murphy's full scripts (not auto-captions) — say so here rather than
present them as a transcript. Reel ids: `DdjWI7CDKC3`, `DdhU6_QAXnX`, `DdgxTr7AcvO`,
`DdewD5fFOjE`, `DdeMk-bFdui`, `DdbnwpOiEZJ`, `Ddj5rEuCSpf`, `DdcLYmyCCXH`, `DdZmhq3D2i_`.

Coverage was checked claim-by-claim against `audit/` + `standard/` before writing anything new
(never from a grep-hit count alone — see the pack's own "how to use" note above). Five of the
nine reels named a gap with no existing lens or rubric criterion; those five became four new
`standard/` docs (one doc, `auth-token-lifecycle`, covers two reels — session fixation and
reset-token expiry are the same "credential lifetime" concern). One claim was extended onto an
existing criterion instead of a new doc (clickjacking → `security.md` crit 10, which already
owned CSP). One claim was extended onto an existing doc's criteria (Redis-as-a-database →
`cache-ratelimit.md`, which already owns Redis). Two claims (compliance documents,
vendor-sovereignty) are process/architecture judgment calls, not per-repo pass/fail code
checks, and are recorded here without a graded doc. A fifth item — five AEO findings measured
live against a real a previous storefront product merchant store, not from a reel — is included in this batch because it
surfaced the same day and shares the "answer engines read what you actually served, not what
you intended" theme as nothing else in the standard.

### Security

**L19 — Your AI never set the one header that prevents framing.** *(`DdjWI7CDKC3`.)*
"An attacker just embedded your entire app inside their website. Your users click buttons on
your app while looking at the attacker's page. Purchases, transfers, permission changes.
Invisible clicks. Your AI never set the one header that prevents framing. Direct your AI to
add X-Frame-Options DENY and Content-Security-Policy frame-ancestors. Both headers, every
response."
→ Every response sets both `X-Frame-Options: DENY` (or `SAMEORIGIN` where framing by the same
origin is intentional) and `Content-Security-Policy: frame-ancestors 'none'` (or an explicit
allowlist) — not just the login page, every response.
`grep -rniE "x-frame-options|frame-ancestors" apps/*/next.config.* apps/*/src/middleware.* apps/*/src/**/headers*.ts 2>/dev/null`
Then read: confirm it is set globally (middleware/`next.config` `headers()`), not on one route,
and that `frame-ancestors` isn't left at the CSP default (`default-src` does not cover framing).
**Ruling L19 — extended `security.md` crit 10, not a new doc.** Crit 10 already grades
CSP/HSTS/nosniff presence; it named neither `frame-ancestors` nor `X-Frame-Options`
explicitly, so a repo setting CSP without framing directives passed the existing check while
still being framable. Cost if wrong: a repo ships CSP for XSS and stays open to clickjacking,
and the rubric would keep saying "solid."

**L20 — The cache holds sessions and tokens; treat it like the database it is.** *(`DdhU6_QAXnX`.)*
"An attacker just connected to your Redis instance and read every session token your app
stores. Your AI set up Upstash and left the default connection open. They do not crack
passwords. They copy a session and become any user. Direct your AI to enable ACL. Restrict to
only the commands your app uses. Bind to your deployment IP range. Your cache holds sessions
and tokens. Treat it like the database it is."
→ Redis/Upstash requires auth (not a default/open connection), an ACL restricts the app's
credential to the command set it actually uses (no `FLUSHALL`/`CONFIG` from the app role), and
network access is bound to the deployment's IP range or a private network, not `0.0.0.0/0`.
`grep -rniE "REDIS_URL|UPSTASH_REDIS_REST" apps/*/.env.example apps/*/src/**/redis*.ts 2>/dev/null`
Then check the provider dashboard/IaC for TLS + ACL + network restriction — this is
infra config, not always visible in a grep; the check locates the client, the read is against
the actual instance settings.
**Ruling L20 — extended `cache-ratelimit.md`, not a new doc.** That doc already owns Redis
(rate-limit store, two-tier cache) but every criterion grades cache *correctness*
(replica-safety, TTL, invalidation), none grades *access control on the store itself*. Added
criterion 10. Cost if wrong: a rate-limiter and a session store both correct in behavior, on an
instance anyone on the internet can open with the default port and no password.

**L21 — No password, just an ID that outlives the login.** *(`DdgxTr7AcvO`.)*
"An attacker just logged in as your user without a password. They set the session ID before
your user authenticated. Your user logged in. The attacker shares their session. Your AI never
regenerated it. Direct your AI to regenerate the session after every login using
req.session.regenerate. Regenerate on every privilege change. Set Secure, HttpOnly, and
SameSite flags."
→ The session identifier is regenerated on every successful login and on every privilege
change (role upgrade, re-auth after MFA), so a pre-set/attacker-known session id cannot be
adopted post-login; cookie carries `Secure`, `HttpOnly`, `SameSite`.
`grep -rn "session\.regenerate\|regenerateSession\|\.regenerate(" apps/api/src --include=*.ts`
Then read: a login handler with no regenerate call, or a session library configured
`resave`/`saveUninitialized` without a documented reason, is the finding.
**Ruling L21 — NOT covered; new `standard/auth-token-lifecycle.md` (36).** `auth.md` grades the
authorization middleware chain and JWT lifetime documentation but has no criterion for session
identifier lifecycle. Cost if wrong: a correct login flow that never rotates the session id
lets a pre-authentication session be silently adopted post-login — no error, no log line,
indistinguishable from a normal session on every subsequent request.

**L22 — The return-to that never gets checked.** *(`DdewD5fFOjE`.)*
"An attacker just used your login page to send your users to a phishing site. The URL looks
like your domain. The redirect happens after authentication. Your user trusted it because they
just typed their real password. Your AI built a return-to feature. The destination comes from
a URL parameter your server never validates. Direct your AI to validate redirects against an
allowlist. Reject encoded variants. Audit every redirect in your auth flow."
→ Every post-auth redirect target is checked against an allowlist of same-origin paths before
use; encoded/obfuscated variants (`%2F%2F`, backslash, `\t`/`\n` prefix tricks, protocol-relative
`//evil.com`) are rejected by the same check, not bypassed by them.
`grep -rniE "req\.(query|body)\.(returnTo|redirect|next|continue|redirect_uri)" apps/api/src/routes/auth* apps/web/src/**/login* 2>/dev/null`
Then read: a `res.redirect(returnTo)` (or a Next `redirect()`) with no scheme/host check
feeding it directly is the finding; a same-origin-path allowlist or a signed/opaque state
token is the pass.
**Ruling L22 — NOT covered (0 hits); added as `auth.md` criterion 11.** This is part of the
same auth-flow surface `auth.md` already owns (criteria 2, 7) rather than a standalone
concern, so it was added there instead of a new doc. Cost if wrong: a correctly-authenticated
user is handed, in the same flow that just verified their password, a redirect to a page that
looks like the product they trust.

**L23 — The reset link from four months ago still works.** *(`DdeMk-bFdui`.)*
"An attacker just used a password reset link from four months ago. The token still works. Your
user changed their password twice since then. The old link still logs them in. Your AI never
set an expiration. Direct your AI to expire tokens in 15 minutes. Invalidate after first use.
Rate limit to three requests per hour."
→ Reset tokens expire at ≤15 minutes, are invalidated after first use AND on every subsequent
successful password change (a token issued before the most recent change must not still work),
and issuance is rate-limited (reel's figure: 3 requests/hour/account).
`grep -rn "resetToken\|reset_token\|passwordResetToken" apps/api/src --include=*.ts -A8 | grep -inE "expir|ttl|usedAt|used_at"`
Then read: a token row/JWT with no expiry claim, or a reset handler that doesn't check/consume
`usedAt`, is the finding; confirm the rate limiter on the *request* endpoint (not just the
reset-consumption endpoint) is Redis-backed per `cache-ratelimit.md` crit 1.
**Ruling L23 — NOT covered; same new doc as L21, `standard/auth-token-lifecycle.md` (36).**
Session-fixation (L21) and reset-token lifecycle (L23) are the same underlying concern —
credential lifetime and single-use discipline — described from two ends of the auth flow, so
one doc grades both rather than splitting a two-criterion doc in half. Cost if wrong: a
password change a user believes ends every prior access does not, and the old link is the
attacker's way back in.

**L24 — One request returns a complete map of your backend.** *(`DdbnwpOiEZJ`.)*
"An attacker just downloaded your entire API schema. Every query, mutation, type, and
relationship. Your AI deployed a GraphQL endpoint and left introspection enabled. One request
returns a complete map of your backend. Direct your AI to disable introspection in production.
Enforce query depth limits. Disable field suggestions in error messages."
→ GraphQL introspection is disabled in production; query depth/complexity is limited; error
responses don't suggest field names to an unauthenticated caller. Generalizes to any other
self-describing schema endpoint left reachable in prod: a public Swagger/OpenAPI JSON, an
admin GraphiQL/Playground UI, or exposed `.map` source files.
`grep -rniE "introspection" apps/api/src --include=*.ts` ·
`grep -rln "swagger-ui\|graphiql\|apollo-server" apps/api/src --include=*.ts`
Read-only live check where a GraphQL endpoint exists:
`curl -s "$API/graphql" -H 'content-type: application/json' -d '{"query":"{__schema{types{name}}}"}'`
— a schema back is the finding, an error/disabled-introspection response is the pass.
**Ruling L24 — NOT covered (0 hits); new `standard/api-schema-exposure.md` (37).** This is
distinct from lens 33 (`rsc-payload-exposure`): that lens grades over-broad *row* data crossing
a serialization boundary; this one grades the *schema/metadata* itself being handed out by a
self-describing endpoint — a different attacker action (map the API) from a different surface
(introspection/OpenAPI/Playground), so it earns its own doc rather than folding into 33. Cost
if wrong: every internal mutation, relationship and type name is a single unauthenticated
request away, handed to whoever asks.

### Process claims (not promoted to a graded `standard/` doc)

**L25 — Three documents a solo builder cannot skip.** *(`Ddj5rEuCSpf`.)*
"A founder asked how a solo builder keeps up with compliance when the laws change faster than
the product ships. Not a lawyer. A system. Three documents cannot wait: privacy policy, terms
of service, data processing agreement. Your AI can draft all three in an afternoon. AI
compliance platforms collapsed the cost. $200 a month instead of $25,000. Set a 90-day
compliance calendar."
**Ruling L25 — process, not a code gate.** "Has a privacy policy and ToS" is already graded
(`security.md` crit 9 erasure/export; `psp-account-survival.md` crit 3 privacy-policy
reachability) — those two documents are covered elsewhere. The DPA and the 90-day *recurrence*
this claim actually adds ("laws change faster than the product ships") is an operating cadence,
not a repo state a grep or a curl can observe: nothing in a repo distinguishes a DPA reviewed
last quarter from one never reviewed. Recorded here as the source claim; not promoted. Cost if
wrong (i.e. if this should have been a gate): a stale DPA is invisible to every audit in this
standard until a regulator or a counterparty's legal team reads it, which is the same blind
spot the claim describes — accepted because no repo signal exists to build a check on.

**L26 — Don't single-thread the product through one vendor's API.** *(`DdcLYmyCCXH` +
`DdZmhq3D2i_`, combined — the same claim from a solo-builder angle and an enterprise-legal
angle.)* "What about my small business? Ubuntu. Docker. Postgres. Redis. An open weight model
on vLLM. FastAPI. Cloudflare. Every piece replaceable. Every piece yours. The VPS costs less
than your ChatGPT subscription. When the next model drops, you swap it behind an API endpoint.
Everything else keeps running. Your prompts are your IP." / "The second largest law firm in
America just told OpenAI, Anthropic, and Google 'no thank you.' Latham and Watkins. $8.3
billion in revenue. They bought their own Nvidia GPU servers. Fine tuning open weight models on
their own infrastructure. 'We are not hitching our wagon to one particular company.' When
pricing changes, they do not flinch. When a provider disappears, their operation does not stop."
**Ruling L26 — process/architecture, not a per-repo pass/fail.** A small SaaS calling one
hosted model through one vendor SDK is a legitimate, common, often-correct choice — CLAUDE.md's
own model-routing table makes exactly that call for this operator's own stack. A rule that
failed every single-vendor repo would be wrong more often than right, which fails this
standard's own bar ("would a senior engineer call this overcomplicated"). Not promoted. A
narrower, genuinely gradeable version exists — "model calls are routed through one swappable
call site, not hardcoded to one vendor SDK across N call sites" — and is left as a note for a
future lens rather than added here, to avoid inventing a graded rule under this task's scope
that nobody asked for and that doesn't fit a binary solid/gap for every repo shape. Cost if
wrong: a repo with the AI provider's SDK imported directly in a dozen call sites has no gate
flagging the swap cost, but that cost is real only if the vendor relationship actually breaks —
speculative, not measured.

### AEO — locale/entity integrity (first-party measurement, not a reel claim)

Five findings measured live 2026-09-19/22 against a live merchant storefront (see history), recorded as first-party measurement, not a reel claim, because that is
what they are.

**A1.** Arabic pages (served `lang="ar"`) carry ENGLISH meta descriptions — 8 of 8 product
pages sampled. Answer engines queried in Arabic get a mismatched summary.
**A2.** Brand entity split: a web search for "where to buy <brand> in <country>" answered from a
separate WordPress site (`<brand>.com`) that still has an indexed default "Hello world!"
post; the store itself indexed with a bare title "PecannBee" and a snippet of only
phone+email.
**A3.** No `hreflang` alternates anywhere; homepage has no `rel=canonical` (product pages do);
`/en/products/<slug>` returned `lang="ar"` with the store-wide description instead of an
English product page.
**A4.** AI-crawler policy differs per domain: on a live merchant domain, Cloudflare returns 403 to
TRAINING crawlers (GPTBot, ClaudeBot, CCBot, Bytespider) while ANSWER/search crawlers
(OAI-SearchBot, ChatGPT-User, Claude-SearchBot, Claude-User, PerplexityBot,
meta-externalagent, Googlebot) get 200; other a previous storefront product stores allow all. `robots.txt` allows all, so
the block is an edge rule, not `robots.txt`.
**A5.** Thin server-rendered text: homepage ~1,072 visible chars (mostly category names),
product page ~722.

**Strengths on the same store** (the passing reference shape): product JSON-LD with
`Product`/`Brand`/`Offer`/`OfferShippingDetails`/`FAQPage`; homepage
`Organization`/`Store`/`ItemList`; bilingual `llms.txt`; sitemap with 161 products; `robots`
allow; `security.txt`; `/privacy` and `/terms`.

→ Every localized URL serves meta content matched to its own `lang`/`hreflang` (not a
store-wide English default under an Arabic `lang` attribute); every page (not only product
pages) carries `rel=canonical`; `hreflang` alternates exist and are reciprocal; a single
canonical entity is reinforced everywhere the brand can be found (no stale duplicate domain
left indexed); AI-crawler policy is a deliberate, documented choice per crawler class
(training vs. answer/search), not an accidental default that differs unexplained store-to-store;
rendered text meets a substance floor so the page is not effectively empty to a
non-JS-executing crawler.
`curl -s "$SITE/ar/products/<slug>" | grep -o '<meta name="description"[^>]*>'` — compare
against the `lang` attribute on the same response.
`curl -sI "$SITE/" | grep -i 'link.*canonical\|hreflang'`
`for ua in "GPTBot" "ClaudeBot" "OAI-SearchBot" "PerplexityBot" "Googlebot"; do echo -n "$ua: "; curl -sA "$ua" -o /dev/null -w "%{http_code}\n" "$SITE/"; done`
**Ruling A1-A5 — NOT covered; new `standard/aeo-integrity.md` (38).**
`frontend-quality.md` crit 9 (meta+OG) and crit 11 (structured data + hreflang) grade
*presence* — does a `<meta name="description">` tag exist, does `hreflang` appear anywhere —
and this store passes both while failing every one of A1-A5, because presence and correctness
are different claims: an English description under an Arabic `lang` attribute satisfies crit 9
by simply existing. A1-A3 and A5 are correctness/substance checks `frontend-quality.md` doesn't
make; A2 and A4 (entity consolidation, differential crawler policy) aren't SEO-tag checks at
all — they're cross-domain/cross-crawler-class facts no single-page grep can see. Cost if
wrong: a store that "passes" today's SEO criteria still answers an Arabic query with English
copy, still loses brand searches to a stale WordPress install, and still can't be told whether
its AI-crawler block was a decision or an accident.
