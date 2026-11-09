# real-world-sense — nothing is logical until it makes sense to the person using it

tags: [BOTH]
sources: feedback-sense-audit-real-world-logic (the owner's standard, 2026-10-07); audit reports `sense-audit/{geo,auth-roles,money-lifecycle,prod-data}.md` + `device-audit-2026-10-07.md`; a marketplace launch audit (PRs listed in history)

A vet from another country was offered for a local listing. A signed-out guest was told "verify your ID"
instead of "sign in". About 5,000 green tests had no opinion on either. One read-only audit with
four real-world lenses then found ~75 more: a fake "price collected in <currency>" under a price
the platform never collects; ended auctions shown live; a cancel-before-payment that kept the
money with no refund; per-role KYC making a verified seller re-verify to bid; a video that could
not be seeked.

**The rule:** *every screen, button and message is checked as a real person in a real place
would meet it - what they see must be true, possible and in the order they would expect.*

**Tradeoff:** a slow, judgement-heavy audit pass, against a product whose tests pass and whose
first real user is confused or out of pocket.

## 1. The failure mode

Code is correct against its own model; the model is wrong about the world. Nothing fails, so
nothing is reported, so it is found by the first customer or the owner's phone.

## 2. What to check - four sub-lenses

| # | Criterion | Solid (grade 2) | Gap detection | Severity |
|---|---|---|---|---|
| 1 | **Location pairing** | Directories/services (vets, carriers, agents) are filtered by the item's/viewer's country; times carry a timezone label; a shown currency is either what is charged or says what is charged | list endpoints/screens for services with no `country` param; `toLocale*String` without `timeZone`; a price note ("collected in X") that contradicts the actual charge | High |
| 2 | **Gate order** | guest -> signed-in -> verified -> owner. The sign-in prompt precedes any KYC prompt; the owner is never offered buyer actions on their own item; the server enforces what the button implies and the client maps its error code | handler that checks a verified/KYC flag before the session/token check in the same function; a gate button `disabled` on KYC (so its explaining handler is unreachable); bid/buy panels with no owner check | High |
| 3 | **Money + lifecycle** | Cancel while payment is pending refunds or blocks; nobody pays for something undeliverable; ended/sold items never render live; an unknown value is shown as unknown, never as 0 / 0% | trace each paid object tap -> gateway -> webhook -> expiry/cancel/refund; grep UI for `Math.round(x*100)%` with no "not run" state; public media routes serving video without HTTP Range/206 (cannot seek, iOS refuses to play) | High |
| 4 | **Identity reuse** | One identity verification is reused across roles; a professional role asks only for professional documents | role -> required-documents map: the ID doc listed again under every role is the gap | Medium |

## 3. How to audit

Four parallel read-only auditors, one lens each, plus GET-only probes of live data. Every
finding carries a plain-language scenario and file:line or curl evidence; findings are CLAIMS -
try to refute each before fixing; declined ones get a ruling; business choices go to the owner
as plain questions with a recommendation. Owner device-test screenshots are a primary source:
map each complaint to a root cause first.

## 4. Where it is graded

Any product with users in more than one place, role or paid state. Mostly judge-graded. The
mechanically checkable slices have probes (verified-before-session order, video route without
Range, directory endpoint with no country filter); the rest is explicit judge work, not a
pretend probe.

## 5. Probe precision (calibrated 2026-10-08 on two production codebases)

Three false-positive classes were removed, each pinned by a clean regression twin: a directory
query is something USERS list, so cron/sweep/worker/job code, tenant-scoped (`storeId`) config
reads and a caller's own lists are not directories; the country test reads 40 lines of context
above the `findMany`, where `where` is usually composed; and a route registered with session
middleware (`app.get(path, requireSession, ...)`) enforces the session before any helper in the
file runs, so a KYC-first helper there is not a gate-order defect.

Original incident narrative: [standards incidents](../../docs/history/standards/incidents.md).
