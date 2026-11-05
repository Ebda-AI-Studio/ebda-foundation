# Vendor Provenance

> **Template.** Copy to the root of any repo that carries code taken from another
> repo — a clean-room clone of another company's product, a vendored dependency,
> a scaffold lifted from `ebda-foundation/template`. Enforced by
> `ops/check-provenance.sh`; a row without a 40-hex commit SHA fails the gate.
>
> Modelled on `deepseek-ai/deepseek-harness` `vendor/README.md`, which is the best
> worked example of this contract in the wild: a manifest keyed on exact upstream
> commits, an exhaustive divergence log with a rationale per entry, an explicit
> "intentionally not taken" list, and a CI gate asserting the wiring still matches.

## Why this file exists

A one-way sync becomes a two-way sync by accident. Six months after a clone, nobody
can say which upstream commit it came from, which differences are deliberate and
which are drift, or whether a client's name is still buried in a config. This file
is the answer to all three, and it is only worth anything if it is updated in the
same commit as the code it describes.

## Manifest

One row per directory or package taken from elsewhere. **The commit SHA is
mandatory** — a tag or a branch name is not provenance, because both move.

| Directory | Name here | Upstream name | Upstream version | Upstream repo | Upstream commit |
|---|---|---|---|---|---|
| `packages/example/` | `@acme/example-here` | `@upstream/example` | 1.4.2 | https://github.com/upstream-org/example | `0000000000000000000000000000000000000000` |

## Local modifications

**Keep this log exhaustive — every divergence from upstream must be listed, with
the reason.** An unlisted difference is indistinguishable from an accident, and the
next person to sync will either clobber it or preserve a bug.

1. **`packages/example/src/config.ts`**: replaced the hardcoded tenant list with an
   env-driven lookup. Rationale: the upstream list names live clients of the other company and
   must not exist in this org's history at all — see the scrub list below.
2. …

## Intentionally NOT taken

List what was deliberately left behind and why. Without this, the next sync
re-imports it, believing it was an oversight.

- `apps/admin/src/app/stores/**` — the upstream's multi-tenant admin. This product is
  single-tenant; importing it would drag the whole tenancy model across.
- …

## Scrub list — what must never cross the boundary

Every pattern below is an identifier of the **other** company (the upstream side of the boundary). `ops/check-provenance.sh` greps the
whole tree for these and fails if any appears. Add to this list; never remove from it
without saying why in the divergence log.

| Class | Examples | Why it must not cross |
|---|---|---|
| Client names | `acme-client`, `example-customer` | A separate company's repo naming another company's clients is a confidentiality breach, not a tidiness problem |
| Deploy targets | the other company's Cloudflare account ids, Railway project ids, Vercel project ids | A misfired deploy from this repo lands on the other company's infrastructure |
| CI secret names | the other company's secret-name prefixes and chat ids | A workflow here would silently expect secrets it must never be given |
| Database identifiers | Neon project ids, branch names, connection-string hosts | Same blast radius as a deploy target, with data attached |
| Payment identifiers | the other company's merchant/API references | The client's cost centre, and a live money path |
| Domains | `acme.example`, other client domains | Wrong-company links shipped to users |

## Sync procedure

1. `git -C <upstream> rev-parse HEAD` → the SHA that goes in the manifest.
2. Copy, then re-apply every entry in the divergence log.
3. Run `ops/check-provenance.sh --repo .` — it must exit 0.
4. Commit the code and this file **together**. A manifest updated in a later commit
   is a manifest that was reconstructed from memory.
