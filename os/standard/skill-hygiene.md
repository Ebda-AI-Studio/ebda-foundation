# skill-hygiene — Installed-Skill and Reviewer-Rotation Rubric

tags: [BOTH]
sources: reel lens pack 2026-08 (`@-MM`, `#aidirectedengineering` — L2 stale skills, L5 same-vendor review), live evidence: 19 Google/Gemini skills installed 2026-08-16 with no review-or-dispose step; FWB PR #1099 written and AI-reviewed by the same vendor, `docs/audits/2026-08-31-reel-derived-lenses.md` in force-website-builder

This closes a gap the other 25 lenses do not cover. They grade **the code an agent
produces**. This one grades **the agent's own configuration** — the skills loaded into its
context and the reviewer that checks its work. Both silently decay, and neither decays in a
way any existing gate can see.

## What "solid" looks like

Every installed skill has a recorded install date and a review date, and is re-read or
disposed of on a cadence. No skill is retained purely because removing it feels wasteful.
Code that an AI wrote is reviewed by a *different* vendor, framed adversarially, and which
one builds versus reviews rotates.

## L2 — Skills are prescriptions, not assets

A skill authored for a model that has since been updated dozens of times is not neutral
baggage. It **competes for attention with the instruction being given right now**, and it
encodes workarounds for behaviour the model no longer has. The failure is silent: a stale
skill never errors, it just quietly degrades every response that loads it.

**Apply. Verify. Dispose.**

Gates:

- Every skill install records **when** and **why** — an install with no recorded rationale
  cannot be evaluated later, only accumulated.
- A skill referencing a specific model id, a deprecated API shape, or a since-fixed model
  quirk is **expired**, not merely old. Grep installed skills for pinned model names and
  version-specific workarounds.
- Bulk installs are the highest risk: they arrive as a set, are evaluated as a set, and are
  never revisited individually. Nineteen skills installed in one sitting on 2026-08-16 is
  the live example — the install note records provenance but no review or disposal step.
- Skill count is a cost, not a capability score. "47 skills loaded" is a liability claim.

**Check:** for each installed skill — when was it installed, when was it last read, does it
name a model or API version, and would you install it again today? A "no" to the last is a
disposal, not a discussion.

## L5 — The builder must not be the reviewer

The shortcuts that produce a vulnerability are the same shortcuts that miss it in review.
One vendor's blind spots are correlated across both roles, so single-vendor review measures
style adherence, not correctness.

Live evidence from this org: FWB PR #1099 was authored by Claude and passed by CI's "AI
Review" (Claude) and "Blast-radius scoped audit" (Opus). Both defects that surfaced
afterwards — an unrun prettier gate and a revived `TRUNCATE` — were the author's, and the
same-vendor review passed both.

Gates:

- Review runs on a **different vendor** from the one that wrote the change, framed
  adversarially ("find what breaks this"), not descriptively ("review this").
- Which vendor builds and which reviews **rotates**; a fixed pairing re-establishes the
  correlated blind spot in one direction.
- A same-vendor review is not worthless — it catches convention drift — but it must not be
  the *only* gate on security-relevant or money-path changes.

**Check:** does CI's review step run a different vendor from the one that produced the
diff? If both are the same, the review is a lint pass wearing a reviewer's name.

## L6 — Keep a tool only if it wins a head-to-head

sources: feedback-head-to-head-always-use-the-better-tool (Ahmad 2026-10-08)

Judging a tool by its name or description keeps the weaker one. The 2026-10-08 OS audit first
called cursor/pstack "port ideas only" from descriptions. When the files were read in full,
pstack won five pairs, and cloudflare/security-audit-skill (refute every finding,
`needs_validation` with no severity) beat our `security-auditor`, which is grep one-liners
that rate a missing header as High.

Gates:

- Before keeping, adding or porting any skill, agent, plugin, hook or MCP, pair it with the
  closest thing already installed and **read both in full**.
- Score both on four pillars: trigger and context cost, structure (steps vs reference),
  steering (leading words, leg-work split) and pruning (no no-ops, no sediment, DRY). Then
  score effectiveness: concrete checks, verifiable output, failure modes, false-positive control.
- Quote the deciding passages. The verdict is OURS BETTER, THEIRS BETTER, MERGE (naming the
  sections and the target file) or NO EQUIVALENT, recorded as a Ruling with cost-if-wrong.
- The loser is removed or made user-invoked (`disable-model-invocation: true`). Removal needs Ahmad.
- **Finders are the exception.** When both tools find problems (security, code or bug
  review), the winner is primary and the loser stays as an independent second reviewer,
  after taking the winner's lifts. Two eyes are better than one.
- Internal duplicates count too: keep 1–2 primaries per cluster and make the rest
  user-invoked.

**Check:** for each cluster of overlapping tools, is there a recorded head-to-head newer
than the newest member? If not, there is a gap.

## Why this is a standard and not a preference

Both failures are invisible to every other gate in this rubric. Tests pass, CI is green,
lint is clean, and the audit fleet reports healthy — while the agent is carrying stale
instructions and grading its own homework. Nothing else in `standard/` looks at the
agent's configuration, so if this file does not check it, nothing does.

Full lens pack (21 lenses, incl. the 17 code-auditable ones already covered elsewhere in
this rubric): `force-website-builder/docs/audits/lenses/reel-lenses-2026-08.md`.
