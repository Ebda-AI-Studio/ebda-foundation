# Audit lens packs

Source packs of failure-mode claims, kept verbatim, that feed the graded rubric in
`standard/`.

## Why packs live here and not only in `standard/`

`standard/` is the **rubric**: 41 graded concerns, each reworded into the house
vocabulary. A pack is the **source**: the original claims, in the words they arrived in,
with the concrete scenario attached ("a bakery paying 22% delivery fees…", "14,000 requests
to your login endpoint last night").

Both are needed, for three reasons:

1. **A lens used once is a lost lens.** A pack applied to one repo and then discarded
   bought a single audit. Kept here with a fleet-status line, it re-runs against every repo
   that has not been checked yet.
2. **The mapping has to stay re-derivable.** When a `standard/` doc gets reworded, the
   claim it came from is still here to check the wording against. Without the source, a
   concern can drift until it no longer covers the failure that motivated it — and nothing
   would show that drift.
3. **The scenario is the teaching.** "Configure your WAF" is forgettable; "14,000 requests
   hit your login endpoint last night, all of them scanners, sailing through the Cloudflare
   you already pay for" is not. Graded rubrics necessarily lose that, and the loss is what
   makes a rule easy to skip.

## How to use a pack

Run its checks against a target repo, then **read the code behind every hit before
recording a finding**. The checks are deliberately noisy: they locate candidates, they do
not judge. Recording a grep count as a finding is how an audit manufactures false
accusations — see `~/.claude/.../memory/feedback-audit-findings-are-claims-not-facts`.

Record the outcome in the pack's fleet-status line so the next run knows what is already
covered.

## Packs

| Pack | Source | Lenses | Fed into `standard/` |
| --- | --- | --- | --- |
| [`reel-lenses-2026-09.md`](reel-lenses-2026-09.md) | 12 reels, `@-MM` + `@haydenschmitty`, 2026-09-04; +3 reels 2026-09-19; +9 reels `@mattmurphyai` + 5 live AEO findings, 2026-09-22 | 27 (15 code, 1 a11y, 1 infra, 1 business, 6 code from the 2026-09-22 batch, 1 AEO, 2 process-only) | lens 30 `absent-filter-matches-everything` (L6); lenses 33 `rsc-payload-exposure` (L16), 34 `psp-account-survival` (L17), 35 `model-currency` (L18); lenses 36 `auth-token-lifecycle` (L21, L23), 37 `api-schema-exposure` (L24), 38 `aeo-integrity` (A1-A5); L19 extended `security.md` crit 10, L20 extended `cache-ratelimit.md` crit 10, L22 extended `auth.md` crit 11; L25 (compliance docs) and L26 (vendor sovereignty) ruled process-only, not promoted; the other 14 from the earlier batches graded by existing lenses |
| [`reel-lenses-2026-08.md`](reel-lenses-2026-08.md) | 21 reels, `@-MM` / `#aidirectedengineering`, 2026-08-31 | 21 (17 code, 2 process, 2 business) | lens 26 `skill-hygiene` (L2, L5); the other 17 already graded by existing lenses |
| [`lens-pack-gcc-horse-market-2026-10.md`](../../../docs/history/lens-pack-gcc-horse-market-2026-10.md) | a marketplace launch-readiness day: owner device test + four-lens sense audit, 2026-10-07 (PRs #197–#209) | 4 (1 navigation, 1 state-transition, 1 real-world-sense, 1 lockfile/toolchain) | lenses 39 `navigation-integrity`, 40 `state-transition-integrity`, 41 `real-world-sense`; the lockfile claim extended `deploy-verify.md` crit 8; infra-only lessons (umbra guard restart-all, throttle fail-open) fixed in ops (#206), not lenses |
| [`ebda-2026-10.md`](ebda-2026-10.md) | Ebda AI Studio full audit, 2026-10-26 (12 lens reports consolidated in EBDA-MASTER-FINDINGS-2026-10-26, section 7 = catalogue L01-L87, fully mapped in the pack file) | the Ebda-sourced lenses | every claim ships as a graded lens in `mypovonai-learn/fleet/` (probe + known-bad fixture + clean twin + rubric + pack); rubrics mirrored as `standard/<id>.md`; run with `mypovonai-audit all` |
| _(2026-08-08 reel fleet)_ | earlier reel fleet | — | lenses 21–25: `migration-safety`, `error-surface`, `ai-transparency`, `edge-protection`, `unit-economics` |

## Adding a pack

1. Drop the distilled claims here as `<slug>.md`, one claim per lens, each with its check.
2. Run it against at least one repo and write the report in that repo's `docs/audits/`.
3. For any claim **no existing `standard/` lens grades**, add a `standard/<id>.md` and
   register it in `standard/00-index.md`. That is the step that turns a pack into a gate.
4. **Port it to the product that actually runs the audits.** A `standard/` doc is a rule; the
   check lives in `mypovonai-learn/fleet/`, and only exists once three files land together:
   `lenses/<id>.json`, `probes/<id>.sh`, and `fixtures/<id>/` — a known-bad input proving the
   probe fires, with `expected.grep` pinning the specific finding so the probe cannot pass by
   firing on an unrelated criterion. Copy `standard/<id>.md` to `fleet/rubric/<id>.md` as well:
   that is what the judge reads.
   Measured 2026-09-19: the package vendored 45 rubric docs and shipped 31 lenses, and two of the
   unmatched ones (`absent-filter-matches-everything`, `agent-containment`) were **graded
   concerns** — copied in, quietly ungraded, nobody's decision. `fleet/parity.test.mjs` now fails
   unless every vendored rubric is a lens or a written-down exception, so skipping this step has
   to be deliberate.
5. Add the row above, with the fleet status.
