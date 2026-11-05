# state-transition-integrity — a state change is a conditional write, not an assignment

tags: [BOTH]
sources: feedback-sense-audit-real-world-logic; a marketplace launch audit (KYC review per-role truth, idempotent admin actions; see history); `idempotent-state-change` rule family (`money.md` SAVEPOINT idempotency covers the payment case)

Approve, review, revoke, publish, restore, grant, suspend: each moves an object from one state to
another. Written as `update({ where: { id }, data: { status: 'approved' } })` it silently
assumes the object is in the state the admin was LOOKING at. It may not be: two admins click
within a second; a retry replays the request; the object moved on while the page was open.

What that cost, measured on one marketplace in one audit: a double approve wrote two audit rows
and two push notifications; "restore" on a deleted draft **published** it (skipping payment and
review); suspending twice demoted the seller's listings twice; a user could resubmit KYC
documents while the first set was `in_review`; the admin user page showed the *latest-updated*
profile's status next to the wrong role chip, so an admin approved the wrong role.

**The rule:** *every transition names the state it expects and writes only from it; a repeat is
a no-op or a 409 with exactly one audit row, and a UI shows the per-entity status, never an
aggregate.*

**Tradeoff:** one extra `where` clause and a `count === 0` branch, against paying twice, notifying
twice and publishing what nobody reviewed.

## 1. The failure mode

1. Handler reads the object, checks nothing about its current status, writes the target status.
2. Concurrent or repeated call: both succeed; side effects (audit row, notification, payout,
   demotion) fire twice.
3. A *restore/undo* has no memory of where the object came from, so it picks a hard-coded target
   (usually `published`) and bypasses the gate the object never passed.
4. The UI collapses several entities into one status ("latest updated wins") and the operator
   acts on the wrong one.

## 2. What to check

| # | Criterion | Solid (grade 2) | Gap detection | Severity |
|---|---|---|---|---|
| 1 | Guarded transition | A status write inside an approve/review/restore/grant/suspend/revoke/publish handler is conditional on the current state: `updateMany({ where: { id, status: 'pending' } })` with a `count === 0` branch | Probe tiers: no state read before the write = **high**; a status read-and-branch before the write plus an audit/notify AFTER it (check-then-act, a race runs the side effect twice) = **medium**; a status read-and-branch with no side effect after, or an atomic `updateMany` claim earlier in the function = not a finding (idempotent / already conditional). Read the handler either way | High |
| 2 | Repeat is a no-op, once | A second identical call returns the unchanged result (or 409) and writes NO second audit row / notification | read the handler: audit/notify call must be after the guarded write and skipped on `count === 0` | High |
| 3 | Resubmission blocked while settled | Re-submitting while `in_review`/`approved` is refused (or idempotently replayed for identical input); replacing is only possible from rejected/revoked | read the submit service for status checks before the write | High |
| 4 | Undo derives its target | Restore/undo computes the target from evidence (last audit row) and one function backs both the button and the endpoint; nothing restores to `published` by default | grep `restore` handlers for a literal `published` target | High |
| 5 | Per-entity status in the UI | An admin screen showing N profiles/roles/items shows each one's own status and actions, never an aggregate or latest-updated | read the detail page: a single badge over a list of entities is the gap | Medium |

## 3. What good looks like

    const { count } = await tx.user.updateMany({ where: { id, suspendedAt: null }, data: { suspendedAt: now } })
    if (count === 0) return { id, unchanged: true }      // no second log row
    await recordAdminAction(tx, { action: 'user.suspend', ... })

## 4. Where it is graded

Any repo with an operator/admin surface or an approval flow. Related: `money` (payment
idempotency), `event-log` (one row per real event), `rls`. Probe criterion 1 is a heuristic
static scan (noisy by design: read the handler before recording); 2-5 are judge-graded.
