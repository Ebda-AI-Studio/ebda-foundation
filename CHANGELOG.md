# Changelog

## Unreleased
- DRAIN-NO-REFRESH: `os/ops/drain.sh` stops merging while main's latest completed push CI (`--main-workflow`, default CI) is not success (checked each cycle and before every merge), never refreshes a branch, requires the AI-review CONCLUSION at head for risky PRs (`--review-workflow`, default "AI review"), logs `considering N PRs` + one line per PR, and exits non-zero on a PR list passed as one quoted string, an empty list, or an explicit list with none open (optional positional PR numbers). New `os/ops/relabel-after-review.sh` (installed with the other ops scripts) relabels only on a clean review conclusion. Ruling MERGE-NO-REFRESH-1, standard `merge-gate.md` section "Thin runner pool"; tests `os/tests/drain.test.sh`, `os/tests/relabel-after-review.test.sh`.
- CHAT-FDN: product `whatsapp` is now "Ebda Chat" / "ابدأ شات" (key and `whatsapp.ebda.app` unchanged); `BARE_EN`/`BARE_AR` allow Chat, no longer allow "Ebda WhatsApp". The consumers' other local edits (legal names, `foundedOn`) are NOT adopted: "Ebda Studio" trips the shipped-copy guard and needs its own decision. Consumers must re-run `ebda-foundation sync` to re-lock.

## v0.1.0
- Modules: `brand`, `tokens`, `phone` (Ebda Chat's `normaliseE164`, canonical), `buyer`, `text` (the Store's fold, canonical), `slugs`.
- Vectors: phone (36), buyer-key (8), buyer-key-probe, arabic (35), slugs.
- `buyerKeyProbe` throws below `MIN_PROBE_SECRET_LENGTH` (64); `/health` callers omit the field on error. `new` refuses a slug that is not in `RESERVED_SLUGS`.
- CLI: `sync`, `check`, `status`, `new`. `parity/foundation-parity.test.ts` (lock integrity + vectors).
- Skeleton for `new`: Hono Worker + D1 + SQLite Durable Object + static assets, CI on Umbra.
