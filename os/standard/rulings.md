# rulings — the dispatch record: decide once, cost it, never re-litigate

tags: [BOTH]
sources: mypovonai-learn course-platform build ledger (`docs/course/evidence/platform-build/progress.md`, 10 tasks / 32 rulings W→AF, 2026-09-02/03), `feedback-ruling-form-cost-if-wrong`

## What "solid" looks like

Every decision that overrides a plan, rejects a finding, or accepts a residual is written down as a
**ruling**: what was decided, on what evidence, and **what it costs if it is wrong**. The record
lives with the work (a ledger in the repo), not in a chat. A reviewer disagreeing with a ruling
argues with the recorded cost, not with a remembered intention — and nobody re-opens a settled
question because nobody has to guess why it was settled.

## The form

> **Ruling `<id>` — `<decision>`.** `<the evidence that decided it>`.
> **Cost if wrong:** `<the concrete consequence, in one sentence>`.

Four properties make it work, and all four are load-bearing:

1. **An id, in sequence.** Rulings are referenced from task reports and later rulings. An unlabelled
   decision cannot be cited, so it gets re-argued.
2. **The evidence, not the reasoning.** "Verified against the provider's docs at `<url>`, which says
   `<quote>`" — not "I believe". A ruling that records only a conclusion is an assertion; see
   `verify-before-assert.md`.
3. **Cost if wrong, always.** This is the field people skip and the one that does the work. It forces
   the decision to be *sized*, it tells a future reader whether to spend time re-checking it, and it
   converts "we decided X" into a falsifiable claim. Several rulings on the source build were
   downgraded later precisely because their recorded cost turned out to be smaller than judged.
4. **Written at decision time**, in the ledger, before the next dispatch — not reconstructed in the
   PR description afterwards.

## Must Always

- **Rule on a finding; do not silently accept or silently drop it.** Every review finding ends as
  accepted, rejected on the facts (with the fact), or accepted-as-residual with its cost. A finding
  that simply stops being mentioned reads to the next reader as fixed.
- **Overrule your own brief in writing when it is wrong.** On the source build the controller's own
  brief contained a security defect (a truthiness check where an identity check was required), a
  non-existent field, a claim about build output that measurement falsified, and an instruction that
  could not be satisfied (parameter binding via a CLI that has none). Each was ruled and recorded.
  A plan is a draft — see `feedback-plan-sample-code-is-a-draft`.
- **Record deliberate NON-actions too.** Judgement calls left out (a redaction not applied, a leak
  oracle accepted, a residual accepted) are the ones that get re-litigated hardest, because the
  artifact shows no trace of the decision.
- **Withdraw your own evidence rather than defend it.** When a reviewer's measurement contradicts a
  transcript you produced, the correct move is to label yours a one-time observation and let theirs
  stand — not to re-run it until it agrees with you.
- **Size the reviewer to the diff, and say so.** A 16-line comment-only fix does not need a dispatched
  reviewer; a controller may verify inline **if it records that it read the complete diff and why the
  seat was disproportionate**. Unstated, it is indistinguishable from skipping review.
- **When an agent dies mid-task, verify — do not assume, and do not re-run.** A landed commit with no
  report is a *state to be checked* (tests, lint, typecheck, the diff against base), not a task to
  redo and not a task to trust.

## Must Never

- Never record a ruling without its cost-if-wrong.
- Never re-open a ruling without new evidence; cite the ruling id and say what changed.
- Never let a ruling live only in a chat transcript, a PR comment thread, or a model's memory.

## Grading

| Grade | Looks like |
|---|---|
| 0 | Decisions live in chat. Reviews end without an explicit disposition per finding. |
| 1 | A ledger exists; rulings are recorded but carry no cost-if-wrong, or are written after the fact. |
| 2 | Every ruling has id + evidence + cost, written at decision time, in a tracked file; declined findings and accepted residuals are recorded with the same rigour as fixes. |
