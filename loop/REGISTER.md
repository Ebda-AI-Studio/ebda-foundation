# Register (canonical, seeded 2026-11-11 from business/ebda/QA-LOOP.md)

This file is canonical from now on; QA-LOOP.md points here. Statuses: STILL-OPEN, FOUND, RE-VERIFY, CLOSED. Process: `LOOP.md`.
Update it in the same PR or session as the change. The seed below is copied verbatim and is a snapshot of 2026-11-11 ~07:10Z.

---

Loop: QA on the live QA store (Amelia Aurum, 1bb14d0e-0cb8-4cb4-b939-e889c4bc2ebc, ameliaaurum.com + store.ebda.app admin)
 -> findings logged here (FOUND) -> fix/build PRs -> drain loop merges -> deploy -> RE-VERIFY on production -> close.
Unbuilt source of truth: business/ebda/audits/2026-11-11-plans-vs-main-vs-live.md + verify-AB.md + verify-CDE.md.
Coverage target: every button, every API path, every logic branch, every page/menu; UI/UX consistency admin <-> storefront <-> marketing.

## LOCKED BUILD LOOP (Ahmad 2026-11-11) - runs continuously until launch
1. Source of unbuilt work: audits/2026-11-12-still-open.md (re-triaged daily against main + open PRs), plus every FOUND item below.
2. Build: agents take STILL-OPEN items in priority (money > auth > data > ops > UX), themed PRs into MAIN (never stacked), each with a test that fails on the old code.
3. Merge: the drain loop (scratchpad drain.sh) merges every green + mergeable PR; foundation / ebda-whatsapp PRs gated by the controller.
4. Deploy: automatic on merge; controller confirms /health commit = main tip.
5. Re-verify: every merged item is added to RE-VERIFY below and checked LIVE on the QA store (Amelia) before it moves to CLOSED.
6. QA finds new bugs -> FOUND -> back to step 2. Repeat; the loop never idles while there is STILL-OPEN or FOUND work.

## RE-VERIFY after deploy (fixed in PR -> check live, then move to CLOSED)
- #552 PDP photos (VERIFIED live 02:30Z ar+en)
- #548/#550 semantic search: "gift for my wife", «هدية لمراتي», "something for the sea" return products; "pizza" empty
- #554 refund audit intent; #555 owner delete guard; #557 lockout backoff
- #569 AI never overwrites merchant fields -> re-enter Signal Signet nameAr «خاتم الإشارة», edit English name, confirm Arabic stays
- #551 batch B: save toast after «احفظ المنتج»; empty «المنتجات» category hidden on storefront; English name label; no emoji buttons; «احفظ قواعد الجملة» label
- #572 order copy: «الدفع عند الاستلام» not «cod»; full order number; money «4,850 ج.م» in admin; status toast; size label not «العيار» on Low Tide Ring
- #573 InstaPay first manual payment not "duplicate" -> Amelia subscription state correct
- #545 dashboard cards on DO store (customers count after guest order?)
- #566 time-zone picker Africa/Cairo
- PENDING MERGE: #529 admin /auth/me hang, #571 checkout shipping honesty/cookie/locale/combobox/order address, #565 CI, #575/#562/#568/#577 old-DB ports (refunds, coupons, barcodes, carriers, promo preview, MFA 409, agent key), #570 WA-RPC, #556 name repair, #558 email recipients, #559 typography, #564 support page, #567 publish toast, #576 llms note, #578 test fix, #579 CI lists, #520 marketing copy
- Editor: live preview loads; palette preset applies (QA-G1/G2)
- Dashboard stats appear fast (no 10 s «—»); setup guide shows which steps remain

## FOUND (open, not yet in a PR)
- (add as QA finds them)

### Controller live QA 2026-11-11 (prod 81f766a, Amelia) - all now in PRs
- Storefront `/en/cart|checkout|account|search` 301 to unprefixed Arabic -> ebda-store #647 (+ rule storefront-locale-routes, fdn #34). RE-VERIFY: /en/* stays English live.
- Shopper verify/reset/welcome emails linked to store.ebda.app (admin host) -> #647. RE-VERIFY: real signup on ameliaaurum.com, open inbox link, ar + en.
- Payment retry returned shoppers to a 404 on the platform host -> #686. RE-VERIFY: failed-payment retry lands on the store, in locale.
- ebda.app llms.txt listed Quote/Invite/Ads + "search by meaning (coming soon)" (public-copy rule) -> #605 + #686. RE-VERIFY: llms.txt + JSON-LD = CRM/ERP only.
- Expense receipts + weekly audit archive written to the PUBLIC bucket -> #670 (0 archives existed; read-only count). RE-VERIFY: new receipt not fetchable via media.ebda.app.
- Cold first-hit TTFB 0.9-2.9 s (per-colo edge-cache miss) -> #667 plan (Workers Caching; compat bump blocker). OPEN as plan.

### Closed from the same pass
- Upgrade card on plan-gated insights (#588) - VERIFIED live 2026-11-11 on Amelia insights/cohorts (gold card, upgrade + see-plans).
- Amelia sitemap empty - NOT A BUG: store setting "hide from search engines" is ON (noindex). Default for new stores is OFF. Ahmad to decide whether to switch it off.
- /en/products listing 8 of 9 - false alarm (9 render).

## CLOSED
- see amelia-qa log ~/.claude/handoff/e7d59025-4986-4c96-851c-39e9198e7240-amelia-qa.md
- 03:20Z re-verify #548 LIVE: "something for the sea" -> 5 sea products OK; "pizza" -> [] OK; "خاتم" OK; "gift for my wife" + «هدية لمراتي» -> [] (needs #550 precision/normalisation; #550 auto-closed when base deleted -> reopened by agent against main)
- 03:25Z "gift for my wife" [] = cold embed miss (meta.degraded:true on first call, 4 products on repeat). FOUND: first shopper search after idle loses semantic results -> agent PR SEARCH-WARM-1. #580 = Arabic normalisation (replaces closed #550). RE-VERIFY after deploy: warm + cold, check meta.degraded.
- #581 search warm: budget charge off the timed race (parallel INCRs, own 800 ms bound, fail closed), race = embed only. RE-VERIFY after deploy: GAP=240 scratchpad/idle.sh x8, meta.degraded absent >= 95%; read chargeMs/embedMs logs.
## 03:50Z re-verify pass (admin, Amelia)
- CLOSED #551: English name label «اسم المنتج (بالإنجليزية)», no emoji buttons, «احفظ قواعد الجملة», Arabic page title, save toast «اتحفظ المنتج» - all VERIFIED live.
- CLOSED #572 money format in admin: «4,850 ج.م» VERIFIED live.
- STILL OPEN (in #571, not merged): order detail «طريقة الدفع cod», «Egypt - … شارع شارع … بناية», «توصيل ذاتي».
- #569 test running: nameAr reset to «خاتم الإشارة» 03:49Z, English renamed "Signal Signet Ring" 03:50Z -> check nameAr unchanged at ~03:56Z.
- CLOSED #569 VERIFIED live 03:56Z: English renamed 'Signal Signet Ring', nameAr stayed «خاتم الإشارة», updatedAt = merchant save only (no AI write).
- 04:35Z backup sweep root cause: new store's first alarm 24 h after creation, sweep expected yesterday's manifest -> fix = baseline backup for never-backed-up stores. billing-renewal-daily: 410 STORE_STORAGE_REMOVED from a zombie 'pg' directory row -> skip gone stores (all store-looping crons, sent back to finish class). RE-VERIFY after deploy: next 03:00 sweep has Amelia manifest; billing-renewal-daily succeeds; no P1.
- UI/UX consistency at 390/820/1280/1440 is part of every QA pass (Ahmad 2026-11-11). Audits: audits/2026-11-11-admin-ui-ux-audit.md, 2026-11-11-storefront-chat-shell-ui-audit.md
## 06:45Z
- CLOSED #529 VERIFIED live (API 2fa6fb76 = main): /auth/me 6 calls 108-813 ms (was 12 s abort x3); settings renders, no spinner.
- CLOSED QA-G1: editor live preview loads with real product photos (root cause was the /auth/me hang).
- Editor: hero banner is an empty black block with the store name (merchant has no hero image) -> UI audit to judge default hero for new stores. Editor added to the admin UI/UX audit scope (Ahmad).
- 07:00Z live sweep of the admin audit's 27 "crash" routes on Amelia: 24 OK; insights/cohorts|funnel|segments = plan gate rendered as error «حصلت مشكلة ... حاول مرة أخرى» -> FOUND, sent to admin UI agent (upgrade card + nav lock badge). Admin audit: P0 1 (downgraded), P1 10, P2 9, P3 4 + editor P1 4 P2 5; W1 = #586.
- TODO (Ahmad 07:10Z, approved): after the plan-gate upgrade card ships (admin W2), click upgrade on Amelia as merchant and REALLY upgrade her plan to the one that unlocks advanced analytics (InstaPay manual flow; if it needs a payment approval, use the super-admin path / ask Ahmad to approve the InstaPay request), then re-test every gated page (insights/cohorts, funnel, segments + all plan-gated features) and the rest of admin.
## LOCKED UI/UX program (Ahmad 2026-11-11)
- Admin: W1 #586, W2 #588, foundation #20 (design tokens source of truth) -> PR1 admin imports foundation tokens -> W3 PR2 builder shell, PR3 input scale, PR4 settings shell, PR5 product editor bar, PR6 finance/stock forms, PR7 guard baseline to zero.
- Chat: W1 font+tokens+scale+contrast, W2 inbox/conversation/settings + states + upgrade cards, W3 polish/motion.
- Marketing: W1 font+tokens, W2 home + Store/Chat pages, W3 all 28 pairs at 360/390/820/1280/1440.
- Storefront/shell: #584 #585 #587 (#587 merged), order/success pages = controller QA.
- Every wave: verify live on Amelia / live sites at 390/820/1280/1440 before CLOSED.

## STILL-OPEN added 2026-11-11 from the launch-map cross-check (business/ebda/audits/2026-11-11-launch-map-crosscheck.md)
Items from the old launch map that are not built and were in no current list. Owner/size are suggestions.
- F4 [S]: barcode receive / pick-orders / audit-count flows never exercised live (plan-gated off Growth). Run on a plan that includes it after the Amelia upgrade; fix what breaks. Owner: QA controller + store agent.
- FOLD-COUNTERS [M]: per-request D1/DO/KV counts + latency to Analytics Engine (dataset `ebda_request_budget`, binding `REQUEST_BUDGET`, 1-in-20, always non-2xx/over budget) per docs/plans/2026-11-02-neon-zero.md section 9.2; not on main. Feeds alerts + SCALE-READY (X3). Owner: store agent.
- CHAT-FDN [S]: foundation packages/foundation/src/brand.ts still says `whatsapp: Ebda WhatsApp`; store + WA vendored copies say `Ebda Chat` (Ruling CHAT-FDN-1: upstream must adopt). Change brand + bare-name regexes, re-pin store and WA locks. Owner: foundation agent.
- PERF-PLACEMENT [S]: Smart Placement for the API Worker (neon-zero plan N-21): A/B with k6 now that Neon is gone, keep or revert with numbers (2026-10-22 trial landed in EWR). Owner: store agent.
- PERF-LATENCY [S]: re-measure sign-in (was 3.6-3.9 s), order create (4.3 s) and the 33.5 s TTFB stall on prod after #496/#492; not in any list. Owner: QA controller.
- ISP-188 [S]: Egyptian ISP blocks Cloudflare 188.114.96/97.x. Ebda hosts resolve to 104.21/172.67 today; add a range check to prod-watch for every merchant-facing host incl. custom domains, document in the runbook. Owner: ops/foundation agent.

## Launch-map corrections (2026-11-11, from audits/2026-11-11-launch-map-crosscheck.md)
- Ruling MAP-UMBRA-CI - UMBRA-CI is NOT "Live". Its evidence ("runners online in GitHub") is false now: the two ebda-store runners are `offline` (gh api, 2026-11-11), and Ahmad decided 2026-11-11 not to use the Umbra CI VM (local checks + admin merge; web deploy via Actions or local wrangler). State = Dropped/Superseded. Cost if wrong: a reader trusts "3 runners online" and waits on CI that never runs.
- Ruling MAP-WA-TOKEN - WA-TOKEN is NOT "Live", and its evidence is wrong. wa#55 (d5b0995) is "on-main guard uses checked-out origin/main", a private-repo fetch fix in deploy.sh, not Workers Builds. Measured state (ebda-whatsapp main e513fa7): `.github/workflows/cf-deploy.yml` still deploys from GitHub on every push to main with `CLOUDFLARE_API_TOKEN` in the `production` environment secrets; the file itself says "Durable fix: Cloudflare Workers Builds (WA-DEPLOY-3)", and docs/rulings/WA-DEPLOY-2.md and CI-UMBRA-ON-1.md record the token-in-GitHub residual as accepted and the fix as "queued separately, not built here". What the item required (repo connected to Workers Builds, build token held in Cloudflare, none in GitHub) is not built, and it is a Cloudflare dashboard action on the personal/Whisky 11 account (`as.montaseer@gmail.com`) that also has to reproduce scripts/deploy.sh (D1 migrations, live-commit verify) before cf-deploy.yml can be retired. State = Open (partial: deploy works and is verified from GitHub; the token residual stays). Cloudflare side NOT VERIFIED (no dashboard access from here). Cost if wrong: the token stays reachable by anyone with repo write access while the map says it is gone.
