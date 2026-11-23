# Standard: one alert channel, one scrubber, one set of masks

**Rule.** Every Ebda product sends Telegram alerts with `telegramAlert`, scrubs Sentry events with `scrubEvent` (browser SDKs also `scrubSentryEvent` / `scrubSentryBreadcrumb` / `scrubPostHogCapture`), and masks personal data in logs with `maskPhones`, `redactEmails`, `errClass` and `safeMessage` from `@ebda/foundation/observe`. A product does not write its own phone regex or Telegram POST. Its own entry point keeps only what is product-specific: the alert catalogue (P0/P1/info names), env/config reading, the throttle backend (Redis in Store, per-isolate `memoryThrottle` in Chat), Sentry/Logger wiring and the runbook base URL.

**Why.** Two products masked differently: Chat hid any 8+ digit run in any digit script, the Store's free-text mask skipped Arabic-Indic digits (an Egyptian shopper types `٠١٠١٢٣٤٥٦٧٨`), the Store sent alert bodies and context unmasked, and Chat's Sentry scrub kept URL secrets the Store removed. The stricter behaviour wins everywhere (Ruling FDN-OBSERVE-1).

**Strictness, in one place.** `vectors/redaction.json` (phones in every script, bidi marks, e-mail spellings, URLs, safe messages) runs in the foundation and in each consumer's parity test. Structured denied keys in `fields` (`name`, `customer*`, `phone`, `wa_id`, `token`, ...) never render in an alert; `context` (product-authored JSON: a stack, an error name, queue stats) drops only credential keys (token, secret, password, authorization, api key) and masks every string value. Residual: a person's NAME inside free text (`كلم محمد على ...`) cannot be detected by pattern and is not masked; put names only in denied-key fields or not at all.

**Usage.**
```ts
await telegramAlert({ token, chatId }, { product: 'Ebda Store', level: 'p0', scope: 'store', scopeLine: `${name} (${slug} · ${id8}…)`, title, source, env, body }, { throttle })
Sentry.init({ beforeSend: (e) => scrubEvent(e), beforeSendTransaction: (e) => scrubEvent(e) })
```
Never throws. On Workers pass the promise to `ctx.waitUntil`.

**Gate.** Each product's parity test runs `vectors/redaction.json`; a guard test fails when product code defines its own phone-mask regex or posts to `api.telegram.org`.

sources: store pii-mask / alerts.service, chat observability.ts, ruling FDN-OBSERVE-1.
