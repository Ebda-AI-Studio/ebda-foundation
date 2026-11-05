# model-currency — a model id in shipped config is a fact with a decay date

tags: [BOTH]
sources: reel lens pack `audit/lenses/reel-lenses-2026-09.md` L18 (reel `DdRnkRpxNhC`, watched 2026-09-19 — the reel's own claim did not survive verification, which is what produced this lens); first-party rule: `~/.claude/CLAUDE.md` model-routing table ("always the `*-latest` alias, never a versioned model name — versioned names get deprecated/paywalled without notice"); `skill-hygiene` grades the same decay in an installed skill, not in product code

A reel described an open-source AI product as defaulting to Claude Sonnet 3.5 — a reason,
implicitly, not to take it seriously. The repository says otherwise: `claude-sonnet-5` as the
default, `claude-opus-5` for deep reasoning, `claude-haiku-4-5` for background extraction
(`SenteLabsAI/OpenExecutive`, read 2026-09-19). The stated licence did not survive either: the
badge in the video showed Apache-2.0, the API reports `NOASSERTION`.

Both halves of that are the lens. A model id said out loud is stale within weeks. A model id
**written into config** is stale silently, and the failure arrives at runtime, inside a request
a user is waiting on, long after the commit that pinned it.

**The rule:** *model ids live in exactly one place per product, are the vendor's alias where
one exists, and any versioned pin carries a dated reason — and the vendor's current list is
what confirms it, never memory.*

**Tradeoff:** one constants module and a dated note, against a paid product answering 404 from
its own provider on a Tuesday.

## 1. The failure mode

1. A versioned id is pinned because it was current when the feature was written.
2. The id is duplicated — env default, a fallback literal in code, a README, a skill, a test
   fixture — so "changing the model" means finding all of them.
3. Nothing checks it. A retired id is a 404 from the provider, a paywalled one is a 403, and
   both look like an outage rather than a configuration fact.

The mirror failure is worse and quieter: a **stale id that still resolves**. The product keeps
working, on a model two generations behind, paying the same price for weaker output — and no
error is ever raised, so nothing prompts the check.

## 2. What to check

| # | Criterion | Solid (grade 2) | Gap detection | Severity |
|---|---|---|---|---|
| 1 | One source per product | Every model id resolves from a single constants/config module; no literal ids scattered in call sites | grep the repo for provider id patterns (`claude-`, `gpt-`, `gemini-`, `us.anthropic.`) and count distinct locations; more than one source is the gap | High |
| 2 | Alias preferred over a version | Where the vendor publishes a moving alias (`*-latest`), the product uses it; a pinned version carries a dated note saying why | read the constants module: a bare versioned id with no comment is the gap | Medium |
| 3 | Verified against the vendor, not memory | The id was checked in the vendor's current model list at the time of the change, and the check is recorded in the PR | look for the verification in the PR/commit body; an id changed with no cited source is the gap | Medium |
| 4 | Failure is loud and named | An unknown/retired model id fails at boot or on first call with a message naming the id and the config key — not a generic 500 | grep the provider client for error handling around model-not-found; a bare rethrow is the gap | Medium |
| 5 | Docs and fixtures follow the code | README, skills and test fixtures do not name a different id from the one shipping | grep docs + tests for ids and compare against the constants module | Low |

## 3. What good looks like

One module, aliases where they exist, a dated note where they do not:

    // Verified against the vendor's model list on 2026-09-19.
    export const MODELS = {
      default: 'claude-sonnet-5',
      // Pinned: the alias moved and the 1M-context behaviour is load-bearing here.
      longContext: 'claude-opus-5', // review 2026-12
    } as const;

…and a provider client that says which key is wrong when the id is rejected, rather than
letting a 404 surface as an outage.

## 4. Where it is graded

Any product that calls a hosted model, and any repo that documents one. Related but distinct:
`skill-hygiene` grades the ids inside installed **skills**, `deps` grades the package, and
`docs-parity` catches a stale stack name in a README. This one grades the id the running
product sends to the provider.
