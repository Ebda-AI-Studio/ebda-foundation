# Closed-loop audit: a finding without a rerun is half an audit

**sources:** `reference-audit-lens-packs`, `reference-audit-fleet-and-build-playbook`

## The claim

An audit that ends in a report is not finished. The loop is:

**identify → fix → verify by RERUN → keep building**

The rerun is the part that gets dropped, and it is the only part that proves anything.
Everything before it is a claim: the finding is a claim about the code, and the fix is a
claim about the finding. Only re-running the same check against the changed code turns
both into facts.

## Where this came from

A builder-tooling company watched sixty days of behaviour and rebuilt their product around
this shape, having previously sold 181 courses. What the data told them:

> Builders do not want to stop building to take a course. They are building something
> right now, and they need to identify what is wrong with it, fix it, and move on. Right
> now.

So the unit of work became one cycle — an audit identifies the issue, a capability scoped
to *that exact finding* helps resolve it, and a rerun verifies the fix held — with the
deeper material available but optional. Pricing followed the same logic: an audit, a
rerun, and a scoped skill are each separately priced, because a rerun is a first-class
step and not an afterthought.

The transferable part is not the pricing. It is that **the rerun is a named, budgeted step
in the loop**, which is exactly what makes it happen.

## What this requires of our audit fleet

1. **Every finding names the check that would prove it fixed.** Not "verify the fix" —
   the actual command, test path, or query, written at finding time while the reasoning is
   loaded. A finding whose verification is left to the reader gets closed on assertion.

2. **Prefer a gate to a result.** A one-time audit finds today's instance; a test in the
   repo finds the one written next month. When a lens can be expressed as an executable
   check, ship it as a test in the target repo and record that in the pack's fleet status.
   The lens has then been spent once and kept forever, which is the whole argument of
   `reference-audit-lens-packs`.

3. **The rerun runs against the CHANGED code, not the branch that found it.** A rerun on a
   stale checkout re-reports the original finding or re-passes the original pass; either
   way it measures nothing. Re-run after the fix lands, and say which commit it ran on.

4. **A fix is scoped to the finding.** Refactoring around a finding makes the rerun
   ambiguous: when the check passes, you no longer know whether the fix worked or the code
   moved out from under it.

5. **Declined findings close the loop too.** A finding you rule against is closed by a
   ruling with evidence and a cost-if-wrong, per `standard/rulings.md` — not by silence. A
   finding that simply stops being mentioned reads as fixed.

## The failure this prevents

An audit produces twelve findings. Eight are fixed, three are ruled against, one is
quietly forgotten. Three months later the same audit runs and produces twelve findings
again, and nobody can tell which are new, which regressed, and which were never addressed
— because no run was ever tied to a commit and no fix was ever tied to a rerun. The fleet
then measures its own output rather than the codebase, and its pass rate becomes a number
about the auditor.

## The check on this standard

For any audit run: can you name, for each finding, the commit the fix landed in and the
rerun that passed on it? If not, the loop is open, and the finding's status is unknown
rather than fixed.
