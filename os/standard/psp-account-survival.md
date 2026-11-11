# psp-account-survival — the processor reads your site before it pays you

tags: [BOTH]
sources: reel lens pack `audit/lenses/reel-lenses-2026-09.md` L17 (`#claudecode #vibecoding` launch-advice reel `DdUmUNPB_0g`, watched 2026-09-19); live evidence: `mypovonai.com` sells token packs and answers 404 on `/terms`, `/refund`, `/privacy`, `/support` (measured 2026-09-19); Polar merchant review of the same product, 2026-09-13

`money` grades the payment path: signatures, idempotency, state machines, reconciliation. All
of it can be correct while the account that receives the money is suspended — because the
processor is not grading the code. It is reading the site, counting the disputes, and looking
for the document you would submit if a cardholder complained.

Three failures, in the order they bite:

1. **Activation.** The processor crawls the live site before releasing payouts. No refund or
   cancellation terms, and no visible way to reach a human, and the money is held while pages
   get written — after customers have already paid.
2. **The dispute ratio.** The threshold is a percentage, so a small merchant is the exposed
   one: at ~200 transactions a month, **two** chargebacks is 1%, past the common 0.75% review
   line. The two cheapest causes are a statement descriptor the cardholder does not recognise
   and a charge they did not expect (an overage, a renewal).
3. **The evidence.** A dispute is decided on documents. Explicit usage terms — what a unit
   buys, what expires, what renews — are what gets submitted; "the app was working" is not
   evidence.

**The rule:** *before the first live charge, the paying surface links refund, cancellation and
privacy terms, shows a support contact, and the statement descriptor is set to a string the
buyer will recognise.*

**Tradeoff:** four short pages and one dashboard field, against a suspension that stops all
revenue at the moment the product starts working.

## 1. Merchant of record changes what is covered, not whether it applies

With a merchant of record (Polar, Paddle, Lemon Squeezy) the MoR is the seller: it owns the
card relationship, hosts its own terms at checkout, and carries chargeback liability. That
covers the card-network half. It does **not** cover the review half — the MoR still reviews
the merchant it is fronting, and its reviewer reads your site. Nor does it cover reachability:
a confused buyer who cannot find a contact on your site emails the MoR, and repeated contacts
are a signal about you.

So under an MoR the criteria below still apply, with the liability column relaxed and the
activation and reachability columns unchanged.

## 2. What to check

| # | Criterion | Solid (grade 2) | Gap detection | Severity |
|---|---|---|---|---|
| 1 | Refund + cancellation terms exist and are reachable | A page stating refund eligibility, window, and how to cancel, linked from the page that takes money | `curl` the live site for `/terms`, `/refund`, `/cancellation`; grep the paying page for a link to them. 404 on all is the gap | High |
| 2 | Support contact visible on the site | An address or contact route on the paying surface — not only in the processor's dashboard | grep the rendered paying page for `mailto:` or a contact route; check it resolves to a mailbox that actually receives (MX present) | High |
| 3 | Privacy policy published | Required by the processor and by the app stores; also the page a reviewer looks for first | `curl /privacy`; confirm it is in the sitemap | Medium |
| 4 | Statement descriptor set and recognisable | The descriptor names the product or domain the buyer visited, not a legal entity they have never seen | read the descriptor in the processor dashboard; compare against the brand on the checkout page | High |
| 5 | Overage, renewal and expiry stated before the charge | The buyer sees what recurs, what expires and what an overage costs, on the page where they pay | read the paying page copy; any charge condition not stated there is the gap | High |
| 6 | ToS names the units sold | Tokens/credits/seats defined, with expiry and usage limits, in a document that can be submitted as dispute evidence | grep the ToS for the unit the product bills in; absence is the gap | Medium |
| 7 | Dispute ratio is monitored with a threshold alert | Someone is told at the first chargeback, not at the review | confirm an alert or a scheduled read of the processor's dispute count; absence is the gap for any account under ~500 tx/month | Medium |

## 3. What good looks like

The paying page carries, within one click: refund terms, cancellation, privacy, and a contact
address that resolves. The checkout shows the same brand string that will appear on the
statement. The ToS defines the unit sold and its expiry. And the first chargeback raises an
alert, because at low volume the second one is already a review.

## 4. Where it is graded

Every repo that takes money from a card, directly or through a merchant of record. Not
applicable to invoice-only products (a bank transfer has no chargeback and no descriptor), and
criterion 4 is not applicable where the MoR's own descriptor is used — which is itself worth
recording, since that descriptor is then the string the buyer must recognise.
