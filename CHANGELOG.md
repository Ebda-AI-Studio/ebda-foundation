# Changelog

## Unreleased
- Company Arabic name: `nameAr` and `company.shortNameAr` now use «ستوديو» (Ahmad 2026-11-11). `legalNameAr`, `legalNameEn` and `foundedOn` are deliberately NOT changed or added until the company papers arrive. Ebda Store and Ebda Chat must run `ebda-foundation sync` to re-lock.
- CHAT-FDN: product `whatsapp` is now "Ebda Chat" / "ابدأ شات" (key and `whatsapp.ebda.app` unchanged); `BARE_EN`/`BARE_AR` allow Chat, no longer allow "Ebda WhatsApp". The consumers' other local edits (legal names, `foundedOn`) are NOT adopted: "Ebda Studio" trips the shipped-copy guard and needs its own decision. Consumers must re-run `ebda-foundation sync` to re-lock.

## v0.1.0
- Modules: `brand`, `tokens`, `phone` (Ebda Chat's `normaliseE164`, canonical), `buyer`, `text` (the Store's fold, canonical), `slugs`.
- Vectors: phone (36), buyer-key (8), buyer-key-probe, arabic (35), slugs.
- `buyerKeyProbe` throws below `MIN_PROBE_SECRET_LENGTH` (64); `/health` callers omit the field on error. `new` refuses a slug that is not in `RESERVED_SLUGS`.
- CLI: `sync`, `check`, `status`, `new`. `parity/foundation-parity.test.ts` (lock integrity + vectors).
- Skeleton for `new`: Hono Worker + D1 + SQLite Durable Object + static assets, CI on Umbra.
