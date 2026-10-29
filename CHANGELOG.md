# Changelog

## v0.1.0
- Modules: `brand`, `tokens`, `phone` (Ebda WhatsApp's `normaliseE164`, canonical), `buyer`, `text` (the Store's fold, canonical), `slugs`.
- Vectors: phone (36), buyer-key (8), buyer-key-probe, arabic (35), slugs.
- `buyerKeyProbe` throws below `MIN_PROBE_SECRET_LENGTH` (64); `/health` callers omit the field on error. `new` refuses a slug that is not in `RESERVED_SLUGS`.
- CLI: `sync`, `check`, `status`, `new`. `parity/foundation-parity.test.ts` (lock integrity + vectors).
- Skeleton for `new`: Hono Worker + D1 + SQLite Durable Object + static assets, CI on Umbra.
