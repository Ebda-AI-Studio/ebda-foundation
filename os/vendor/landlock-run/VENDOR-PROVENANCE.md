# Vendor Provenance — landlock-run

Uses the contract in `template/VENDOR-PROVENANCE.md`. Enforced by `ops/check-provenance.sh`.

## Manifest

| Directory | Name here | Upstream name | Upstream version | Upstream repo | Upstream commit |
|---|---|---|---|---|---|
| `vendor/landlock-run/` | `landlock-run` | `@deepseek-ai/landlock-run` (`native/landlock-run/packages/entry`) | 0.1.2-rc.1 | https://github.com/deepseek-ai/deepseek-harness | `76fda729799fe9b3848dbe2c211d4b231032b81e` |

**License: BSD-3-Clause** — note this differs from deepseek-harness's root MIT.
`LICENSE` in this directory is the upstream file, preserved verbatim. Confirmed
against `native/landlock-run/package.json` (`"license": "BSD-3-Clause"`), not a
README badge.

## Local modifications

None. `main.c` is byte-identical to upstream at the commit above. If that ever
stops being true, every divergence must be listed here with its rationale —
an unlisted difference is indistinguishable from an accident.

## Intentionally NOT taken

- The npm packaging (`packages/linux-x64`, `packages/linux-arm64`, `packages/entry/src/index.ts`)
  and its prebuilt binaries. We build from source on the guest at image time;
  pulling prebuilt binaries from npm would add a supply-chain surface to the very
  thing we are adding to reduce one.

## Why it is here

`ops/lib/sandbox.sh` wraps it so unattended agent shell on the umbra Linux guests
runs under a filesystem allow-list instead of with the launching account's full
privileges. See `standard/agent-containment.md`.

## Scrub list — what must never cross the boundary

Not applicable: nothing from our products goes *into* this directory. It is upstream
code taken as-is. The table is retained so `ops/check-provenance.sh` has a
contract to parse.

| Class | Examples | Why it must not cross |
|---|---|---|
| Client names | other companies' client names | upstream code must stay upstream-identical |
