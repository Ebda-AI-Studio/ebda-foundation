# Money standard evidence (predecessor products, frozen)

Moved out of `os/standard/money.md` in the Ebda takeover: these are measurements on the predecessor fleet, kept as history.


## Evidence (filled during audit, per repo)

### Evidence — FWB, measured 2026-09-04 (criteria 15-16)
- **Criterion 16 is preventive here, not a live defect.** Every `* 100` / `toFixed(2)`
  hit across `apps/**` is PERCENTAGE math (discount %, margin %, segment share), not
  currency conversion — `product-pricing.ts:92`, `display-helpers.ts:62`,
  `insights/segments/page.tsx:132,134`, `products/[productId]/edit/page.tsx:841,873`.
  FWB also carries the unit in the identifier (`totalMonetaryFils`, `regularFils`),
  which is the practice that makes an exponent bug visible in review. No
  currency→exponent table exists, so the criterion still applies the moment a
  second currency is added.
- **Criterion 15, internal half: strong.** `apps/api/src/lib/inngest/webhook-offload.guard.ts`
  documents three idempotency layers that must all agree before a mutation runs, and
  `inngest/client.ts:181` ties the idempotency key to the inbox row's unique key.
- **Criterion 15, outbound half: NOT VERIFIED in this pass.** Whether the key sent to
  MyFatoorah is derived from the attempt or generated fresh per retry was not
  established; `myfatoorah` appears in `apps/api/src/config/index.ts` and three UI
  files. Left as an open audit item rather than graded from the internal evidence —
  a strong internal guard says nothing about what crosses the boundary.
- FWB: criteria 9–14 all PASS as of 2026-08-17. Dedup is `Order.idempotencyKey` / `WebhookEvent.idempotencyKey` `@unique` in `packages/database/prisma/schema.prisma`, plus a documented "idempotency layer 2" upsert for deliveries that race past the application check.
- gcc-horse-market: criteria 9–14 all PASS as of 2026-08-17. Dedup is `@@unique([provider, externalPaymentId, status])`.
- WBS: …
