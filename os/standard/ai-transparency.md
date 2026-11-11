# 23 · AI transparency & synthetic-content disclosure

**Concern:** the product generates content with a model, a user consumes it, and the law now requires them to know that.

The EU AI Act's transparency obligations became enforceable **2026-08-02**. They apply to *synthetically generated information* (SGI) — text, images, audio, video, avatars produced by a model — and they attach to whoever puts that content in front of a user. Obligation follows **the user's location, not the company's**: a single EU customer is enough. GDPR has worked this way since 2018; this is the same reach, new subject matter.

This lens is not legal advice. It is the set of things an engineering team can actually build, so the question "can we show what we generated and prove the user consented" has an answer.

## Grading criteria

| # | Criterion | Severity |
|---|---|---|
| 23.1 | Every user-facing AI-generated output carries a visible, non-removable disclosure — not a buried footnote | Critical |
| 23.2 | Synthetic **media** (image/audio/video) carries an embedded marker (metadata and/or watermark) that survives download, not just an on-page label | High |
| 23.3 | An affirmative, un-prechecked consent gate exists before any user input is sent to a model; consent is versioned and revocable | Critical |
| 23.4 | An immutable generation log records, per output: timestamp, model + version, the triggering input, the tenant/user, and where it was published | Critical |
| 23.5 | The generation log is append-only and retained long enough to answer an audit ("what did your system generate on <date>") | High |
| 23.6 | Disclosure survives the **publish** path — content generated in admin and rendered on a storefront is still labelled at render time | Critical |
| 23.7 | Jurisdictional reach is known: the product can answer "do we have users in a regulated region", rather than assuming it does not | High |
| 23.8 | Disclosure strings are i18n'd, including RTL, like all other user-facing copy | Medium |

## Traps

**The generator is not the publisher.** AI-written product descriptions, SEO copy, translations and FAQs are usually generated in an admin tool and then *rendered on a public storefront*. The obligation lands at render. A label in the admin editor satisfies nothing.

**Storage is not a log.** Persisting the generated text on the row it belongs to does not tell you which model produced it, from what prompt, or when. That is a separate, append-only record — the same shape as the money event-log in `event-log.md`.

**"We only sell locally" is a claim, not a control.** Geofencing misses VPNs, country dropdowns get ignored, and ToS exclusions do not hold while you are still collecting the data and serving the content. Measure where users actually are before relying on absence.

**Human-edited AI output is still AI output** unless a human materially authored it. Track provenance through edits rather than clearing the flag on first save.

**Retrofitting is expensive; the log is the hard part.** Labels are a day of work. Reconstructing six months of "what did we generate" is not possible after the fact — instrument the generation endpoints first.

## Verify

Generate one output of each modality, publish it through the real path, and confirm from the **public** page that the disclosure renders. Independently query the generation log for that exact output and confirm model, prompt, timestamp and destination are all recoverable.
