# absent-filter-matches-everything — a dropped condition is not a narrower query, it is a wider one

tags: [BOTH]
sources: reel lens pack `audit/lenses/reel-lenses-2026-09.md` L6 (`@haydenschmitty`, 2026-09-02); `force-website-builder` P0 2026-09-03 (cash-on-delivery return refunded an arbitrary other order)

Born from a claim that arrived from outside — "there is at least one misused dynamic condition in
your app's ORM code" — landing the day before the same failure was paid for inside: a gateway refund
on a cash-on-delivery order refunded **a different customer's order**, restored its inventory,
reversed its ledger and emailed a refund notice to someone who had returned nothing.

The mechanism was one line. `findFirst({ where: { transactionId } })` where `transactionId` was
`undefined`, because the column is nullable and cash-on-delivery payments legitimately carry no
transaction id. Prisma **drops** `undefined` keys, so the `where` emptied and `findFirst` returned
the first row in the tenant.

**The rule:** *a filter built from a value that can be absent must be proven present before the
query runs, or expressed so that absence cannot match.* An absent condition does not narrow the
result set — it removes the constraint.

**Tradeoff:** one guard per optional filter and a test that passes the absent case, against a class
of bug whose signature is a correct-looking query returning a plausible wrong row. Nothing throws.
Nothing logs. The wrong record simply flows downstream and every subsequent step is right about the
wrong thing.

## 1. The failure mode

Three things have to be true at once, and in an AI-built codebase they routinely are:

1. A column is nullable, or a parameter is optional.
2. A query filters on it directly, because the shape reads naturally.
3. The ORM treats "key absent" as "no constraint" rather than "match nothing".

The third is the one people do not hold in their head. `WHERE x = NULL` matches nothing; a `where`
with the key **removed** matches everything. Those are opposite outcomes reached from the same
absent value, and which one you get depends on the ORM's serialisation, not on the SQL you pictured.

It survives review because the code is not wrong-looking. It survives testing because fixtures
populate the field. It survives production until the first row that legitimately lacks the value —
which, for cash-on-delivery in a market where that is the dominant payment method, is not an edge
case but the common one.

## 2. What to check

| # | Check | Why | Effort |
| --- | --- | --- | --- |
| 1 | Every `findFirst`/`findUnique`/`updateMany`/`deleteMany` whose `where` reads an optional or nullable value | These are the queries where an empty `where` silently becomes a full-table match | Medium |
| 2 | The nullable columns in the schema, cross-referenced against the filters that use them | A `String?` used as a lookup key is the signature; the schema is the authority, not the type at the call site | Low |
| 3 | Non-null assertions (`!`, `as`, `NOT NULL` casts) on values the schema says are nullable | The assertion is how the absent value gets past the type system to the query | Low |
| 4 | A test that passes the absent value and asserts a rejection — not a row | Fixtures always populate the field; only a deliberate absent case exercises the collapse | Medium |
| 5 | Whether the guard is at the producer or the query | A guard at one caller leaves every other caller exposed; the query itself is the single place that cannot be bypassed | Medium |

## 3. What good looks like

The query refuses an absent key before it runs, and says so in a way that names the real problem:

    if (!request.transactionId) {
      throw new AppError(400, 'PAYMENT_NOT_REFUNDABLE', '…has no provider transaction to refund');
    }

…and the lookup that feeds it constrains the column so the absent case cannot be selected at all:

    where: { orderId, status: { in: [...] }, transactionId: { not: null } }

Both, not either. The lookup filter makes the error name the actual condition; the guard at the
query makes it impossible for a future caller to reintroduce the empty `where`. Each is proven by
removing it and watching a named test go red — see `mutation-proof`.

## 4. Where it is graded

Any repo using an ORM that serialises conditions from an object. Prisma is the case in evidence
(`undefined` keys are dropped); the same shape exists wherever a query builder skips absent values
rather than rejecting them. Not applicable to hand-written SQL with bound parameters, where an
absent bind is an error rather than an omission.
