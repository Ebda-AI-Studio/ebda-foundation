# Social posting in the OS brain (2026-11-11)

**Scope (Ahmad, 2026-11-11, replaces the first brief):** the OS posts ONLY to the **Facebook Pages** and **LinkedIn company pages** of
**Whisky 11** (English, US + UK buyers) and **Ebda AI Studio** (Egyptian Arabic first, English second; Ebda Store at ebda.app, Ebda Chat at
wa.ebda.app). Each post is written copy with one image, scheduled. For the first 14 days every post goes to Ahmad on Telegram a day ahead
(approve / ask for an edit / skip). After that it auto-posts and sends one daily digest. The switch is per brand, and the clock starts at the
first approved post.

**Out of scope (Ahmad):** Instagram (feed + Reels) and TikTok. Ahmad posts those himself. Instagram reaches Facebook through Meta's own
Accounts Center sharing. The OS never re-posts Instagram content, and its Facebook schedule keeps clear of those shares (section 5).

Finish line:
- **What must work:** draft, then Telegram preview a day ahead, then Ahmad approves, then the post publishes once at its slot. The 14-day window
  then flips to auto-post. The daily digest runs. Failure alerts reach Ahmad.
- **Exercised:** brain `tick` + `digest` crons, `/social/*` routes, the signed decision page, the Facebook + LinkedIn adapters (mocked at HTTP),
  and the Mac job (real render + one real `claude -p` dry run).
- **Must not change:** the existing OS pipeline (findings, hands, questions, the 3/day message budget for OS alerts) and the cron list.
- **Done:** brain tsc 0 + full vitest green, os run-all green, PR green. No merge, no deploy.

## 1. What can post publicly this week (researched 2026-11-11, official docs)

| Network | Public this week? | Why |
|---|---|---|
| Facebook Page | **Yes, after Ahmad's Meta app setup (about 30 min)** | Standard Access works on Pages you own without App Review ([access levels](https://developers.facebook.com/docs/graph-api/overview/access-levels), [app review: own business](https://developers.facebook.com/docs/instagram-platform/app-review)). Business Verification is only needed for Advanced Access. **The app must be Live**: Development-mode content is visible only to app-role users ([app modes](https://developers.facebook.com/docs/development/build-and-test/app-modes)). We infer that Live with Standard-only permissions works on his own Pages. The first post must be checked logged-out (INFERRED, test it). |
| LinkedIn company page | **No, not until the Community Management API is approved** | Organization posting needs `w_organization_social`, and only an approved Community Management (or Advertising) API product grants it ([posts API](https://learn.microsoft.com/en-us/linkedin/marketing/community-management/shares/posts-api), [increasing access](https://learn.microsoft.com/en-us/linkedin/marketing/increasing-access)). Development tier is enough for this volume (500 calls/app/day, 12 months to upgrade) ([app review](https://learn.microsoft.com/en-us/linkedin/marketing/community-management-app-review)). Access is only for **registered legal organizations**, with a verified business email and a Page super-admin verifying the app. Before approval, only member posts work, through the self-serve "Share on LinkedIn" product (`w_member_social`), and those post as Ahmad, not the company ([share on LinkedIn](https://learn.microsoft.com/en-us/linkedin/consumer/integrations/self-serve/share-on-linkedin)). Review time is not documented. The realistic gate is the Ebda Studio legal papers. |

Versions pinned in `wrangler.jsonc` vars: Graph API `v27.0` ([page/photos](https://developers.facebook.com/docs/graph-api/reference/page/photos/)) and
LinkedIn `202610`. LinkedIn sunsets `202511` on 2026-11-16, so a pinned version must move about yearly. All three APIs are free. No docs list
any price (INFERRED).

## 2. Architecture

```
Mac (launchd social-content, 04:20 daily)                     Cloudflare brain (ebda-os-brain, existing Worker + BrainDO)
  social-content.mjs                                           tick (*/5): socialTick
    reads GET /social/calendar + /social/edits                   - expire unanswered posts (slot + 12 h)
    claude -p --model sonnet  -> copy JSON                       - previews: draft -> Telegram (photo + text + 3 buttons) at slot-24 h
    brand HTML template -> headless Chrome -> JPEG               - publish: approved + due + gate ok -> claim -> adapter -> published
    POST /social/drafts (one per request, INGEST_TOKEN) ----->   - reconcile stuck / uncertain posts from the Page feed
                                                               digest (05:00 UTC): socialDigest (one message, once a day)
Ahmad on Telegram: signed URL buttons -> /social/d/:id page (GET renders, POST decides)
                   or a button press forwarded to /telegram/webhook (s:<id>:a|e|k), or the controller -> POST /social/decide
```

- **Storage:** calendar rows in BrainDO SQLite (`social_posts`, `social_brands`, `social_meta`). Images go to the existing KV namespace
  (`social:img:<id>:<rev>`, 90-day TTL). There is no R2 and no new binding: both platforms take the image bytes (Facebook multipart `source`,
  LinkedIn `PUT` to its upload URL), so no public media URL is needed.
- **No new cron, no always-on compute:** the work rides the existing 5-minute `tick` and 05:00 `digest`. A social error is caught and logged and
  never blocks the OS tick.
- **Network adapter interface** (`src/social/adapters/types.ts`): `disabledReason(brand)`, `publish()`, and for Facebook only
  `recentPosts()` + `findByText()`. A result is `ok | retry | fatal | uncertain`.
- **Adapters:** Facebook `POST /{page-id}/photos` (multipart `source`, `caption`, `published=true`). LinkedIn does Images
  `initializeUpload`, then `PUT` of the bytes, then `POST /rest/posts` as `urn:li:organization:<id>`, with the commentary escaped
  ("little text"). Both stay **disabled**, and say why in the digest, until their secret exists.

### Safety properties (each one has a test in `os/cloud/brain/test/social.test.ts`)

1. **Approval gate.** While a brand is in its approval window, a post publishes only if `approved_by = 'ahmad'` on **that revision**. The
   check runs when the post is selected, and again right before the network call. A forged `approved_by='auto'` row in the window does not
   publish, and mutation-testing the gate makes the test fail.
2. **At most once.** The row is claimed (`publishing`, then `storage.sync()`) before the call. A lost answer becomes `uncertain` and is
   never blindly retried. For Facebook, the next tick reads the Page feed for the exact text: if found, the post is recorded as published;
   if the feed was read and the post is absent, it is retried; if the feed is unreadable, Ahmad is alerted. LinkedIn `uncertain` alerts Ahmad.
   Before any retry after an ambiguous Facebook error, the feed is checked first.
3. **Retries:** only definite platform errors that create nothing (5xx, 429, Meta `is_transient`) are retried, with 10 min / 30 min / 2 h
   backoff. Fatal errors (Meta 190 token, permissions, LinkedIn 4xx) fail at once with one Telegram alert.
4. **Rate limits:** at most 2 posts per brand per network per 24 h, 5 publishes per tick, and one draft per request. LinkedIn Development tier
   allows 500 calls/day, and we use about 3 per post.
5. **Copy gate at the edge** (`src/social/rules.ts`, also in the prompt): no emoji, never a bare "Ebda", no percentages, no
   client/customer counts, no ratings/reviews/testimonials, and the GCC contracts company never named. Drafts must be `origin: 'os'`, and
   `network` is only `facebook | linkedin`.
6. **Separation of powers:** the Mac content job (INGEST_TOKEN) can write drafts but **cannot approve** them. `/social/decide` takes only
   `SOCIAL_DECIDE_TOKEN`, held by the controller. The signed link is HMAC(`SOCIAL_LINK_SECRET`, id|rev|exp): its GET only renders (link
   previews and prefetchers never decide) and its POST decides.

## 3. Approval window and the per-brand switch

- `brandMode`: **auto** iff `first_approved_at` is set, `keep_approval` is off, and `now >= first_approved_at + SOCIAL_APPROVAL_DAYS (14)`.
  Otherwise **approval**.
- In approval mode: the preview is sent at `slot - SOCIAL_APPROVAL_LEAD_HOURS (24)`, or right away if the draft arrives later than that. An
  unanswered post expires 12 h after its slot. A late approval inside those 12 h still publishes at the next tick.
- In auto mode: drafts are auto-approved (`approved_by='auto'`). If Ahmad turns `keepApproval` on, auto-approved posts that are not yet
  published go back to draft and are asked again.
- Switch: `POST /social/brands/<whisky11|ebda>` `{paused?, keepApproval?}` (SOCIAL_DECIDE_TOKEN). A paused brand neither asks nor posts.
- Edits: "Ask for an edit" stores Ahmad's note. The Mac job reads `/social/edits`, rewrites with the note, and re-submits the same id as
  revision n+1, which is asked again. Approving an older revision is refused.

## 4. Content calendar (proposal: Ahmad edits `os/ops/social/social.config.json`)

| Brand | Facebook | LinkedIn |
|---|---|---|
| Whisky 11 | Tue + Thu 17:00 Cairo (10:00 US East / 15:00 UK) | Tue + Thu 15:00 Cairo |
| Ebda AI Studio | Mon + Wed 20:00 Cairo | Mon + Wed 11:00 Cairo |

That is 8 posts a week. The Mac job fills slots 2 to 8 days ahead, up to 8 drafts a run. Topics rotate deterministically per slot from the config.
Facts are only the ones in the config: COD + InstaPay from day one, and cards through the merchant's own gateway. No numbers, clients or
reviews are invented. Images are the brand templates (`os/ops/social/templates/`): Whisky 11 uses its brand kit palette and Barlow; Ebda
uses night + gold `#B08D57` with IBM Plex Sans Arabic in RTL and no orange. They are rendered free by headless Chrome and `sips`, with no AI
image provider and no cost.

## 5. Instagram shares on Facebook

- Ahmad's Instagram posts reach each brand's Page through Accounts Center sharing. The OS never sources content from Instagram:
  drafts are `origin: 'os'`.
- **Spacing:** before a Facebook post, the brain reads the Page feed (`GET /{page-id}/feed?fields=id,created_time,application{name}`).
  If a post the OS did not make appeared within `SOCIAL_FB_SPACING_MIN` (180), the OS post is deferred to 3 h after it, but never more than
  `SOCIAL_FB_MAX_DEFER_HOURS` (24) past the original slot. An Instagram post Ahmad makes *after* an OS post cannot be foreseen, so the spacing
  is one-sided.
- **Digest:** the same feed read, once a day per brand, lists the Page posts not made by the OS in the last 24 h. Those whose
  `application.name` is Instagram are labelled "shared from Instagram". It is not documented that `application` reads "Instagram" for these
  posts ([post fields](https://developers.facebook.com/docs/graph-api/reference/post/)), so the first live digest settles it. The count of
  non-OS posts is correct either way.
- Reading the feed needs **`pages_read_user_content`** as well as the posting permissions
  ([page/feed](https://developers.facebook.com/docs/graph-api/reference/page/feed/)). Without it, spacing is off and the digest says so.
  Ruling RR-social-spacing: an unreadable feed means the post goes out at its slot. Unknown is not treated as clear, but holding every post
  for an unreadable feed would silence the Page.
- **Whether IG-to-FB sharing is on: UNKNOWN.** No Graph API reads the Accounts Center setting (none found in the docs, INFERRED absent),
  and there is no Meta app or token yet. The first digest after the token exists shows whether shares arrive.

## 6. Daily digest and alerts

- Digest (05:00 UTC, one message, once a day, only when there is something): per brand, the mode ("approval, day N of 14; auto-post
  from ..."), each post from the last 24 h and next 48 h with its status and live link, failed and uncertain posts with the reason, disabled
  networks with the reason, Instagram shares, and LinkedIn token expiry less than 7 days away.
- Alerts: one Telegram message per post when it ends `failed` or `uncertain` and cannot be reconciled.
- Ruling RR-social-budget: social previews and the digest do not count against `MESSAGE_BUDGET_PER_DAY` (3, OS alerts). Ahmad asked for one
  preview per post. Cost if wrong: up to about 8 more Telegram messages a week during the window.

## 7. Tokens

- Facebook: a Page token derived from a long-lived user token **does not expire** (it is invalidated by a password change, role removal or
  app removal) ([long-lived tokens](https://developers.facebook.com/docs/facebook-login/guides/access-tokens/get-long-lived)). If one is
  invalidated, the first publish fails with Meta code 190, which is fatal and alerts at once.
- LinkedIn: the access token lasts 60 days. Programmatic refresh tokens are documented for approved MDP partners
  ([refresh tokens](https://learn.microsoft.com/en-us/linkedin/shared/authentication/programmatic-refresh-tokens)), and it is not stated
  whether a Development-tier app gets one. Until that is known, the secret carries `expiresAt` and the digest warns 7 days ahead. Then Ahmad
  re-runs the token generator (step L5).

## 8. Storage and cost (resource-frugal)

| Item | Monthly | Cost |
|---|---|---|
| Worker + DO | +1 DO RPC per existing tick (about 8.6 k/month) + a few SQL rows per post | inside Workers Paid, $0 extra |
| KV | about 35 image writes, about 4 MB stored (90-day TTL) | free tier, $0 |
| Graph API / LinkedIn API / Telegram | about 35 posts + 60 feed reads + about 70 messages | free |
| Mac job | about 35 `claude -p` Sonnet calls (Max plan) + local Chrome renders | $0 incremental |
| **Total** | | **about $0/month** |

## 9. Ahmad-only steps

**Meta, both brands (about 30 min, needed for Facebook):**
- M1. Open https://developers.facebook.com/apps and choose **Create app**. Pick the use case **"Manage everything on your Page"**. Attach it to
  the Ebda AI Studio business portfolio. One app serves both Pages if you admin both.
- M2. In **App settings > Basic**, add the privacy policy URL (ebda.app/privacy), category and icon, then save.
- M3. In **Use cases > Customize**, add `pages_manage_posts`, `pages_read_engagement`, `pages_show_list` and `pages_read_user_content`. This
  is Standard access with no review, for your own Pages.
- M4. Switch **App Mode** to **Live** (top bar). Development-mode posts are visible only to app-role users.
- M5. Open https://developers.facebook.com/tools/explorer, select the app, then **Get User Access Token** with the 4 permissions. Log in and
  tick **both** Pages. Hand the short-lived token to the controller, which then runs, once:
  `GET /v27.0/oauth/access_token?grant_type=fb_exchange_token&client_id=<app>&client_secret=<secret>&fb_exchange_token=<short>` and
  `GET /v27.0/me/accounts`, checks each Page with `GET /debug_token` (`expires_at = 0`) and `tasks` containing CREATE_CONTENT, and stores
  `{"whisky11":{"pageId","pageToken"},"ebda":{...}}` with
  `npx wrangler secret put SOCIAL_FACEBOOK --config wrangler.deploy.jsonc`. The app secret goes to Keychain `ebda-os-meta-app-secret` and is never printed.
- M6. After the first published post, open it logged out (private window) to confirm it is public.

**Instagram-to-Facebook sharing, each brand's Instagram account (phone, 2 min):**
- S1. In the Instagram app, go to **Profile > menu > Settings > Accounts Center**.
- S2. Under **Accounts > Add accounts**, add the Facebook account that admins the brand's Page, if it is not there yet.
- S3. Open **Sharing across profiles** (older label: "Connected experiences"), choose the brand's Instagram profile, and switch on
  **Automatically share: your posts** (and reels if you want them). Pick the brand's **Facebook Page** as the destination, not your
  personal profile.
- S4. Do the same for the other brand's Instagram account.

The menu labels come from Meta's help article [797182937605779](https://help.instagram.com/797182937605779), read through search
summaries because the page did not render for us, so check them in the live app.

**LinkedIn, one app for both company pages (blocked until a registered legal entity exists):**
- L1. Make sure both company pages exist and that you are a **super admin** of each.
- L2. Open https://www.linkedin.com/developers/apps/new and create a NEW app named "Ebda AI Studio Publisher". Choose LinkedIn Page = the Ebda AI
  Studio page, add the privacy policy URL and logo, then create it. The app must hold no other product.
- L3. In **Settings > Verify**, open the verification link as the page super admin and approve it.
- L4. In **Products > Community Management API > Request access**, fill in the legal name, registered address, website (ebda.app) and a
  **business email on the ebda.app domain** (a personal Gmail fails). The tier is Development.
- L5. After approval, open https://www.linkedin.com/developers/tools/oauth/token-generator and pick the app with scopes
  `w_organization_social r_organization_social`, then log in. The org ids are in each page's admin URL
  (`linkedin.com/company/<id>/admin`). Store
  `{"whisky11":{"orgUrn":"urn:li:organization:<id>","token":"...","expiresAt":"YYYY-MM-DD"},"ebda":{...}}` with
  `wrangler secret put SOCIAL_LINKEDIN`. One token posts to every page where you are an admin (INFERRED from the role rule on the Posts API).

**Brain secrets (the controller can do these at deploy time):** `SOCIAL_LINK_SECRET` (`openssl rand -hex 32`) and `SOCIAL_DECIDE_TOKEN`
(random, Keychain `ebda-os-social-decide-token`). The brain needs `HANDS_BRAIN_URL` to be https for the signed buttons, and
`TELEGRAM_*` is already set.

## 10. Residuals and rulings

- Ruling RR-social-buttons: the tg-relay session polls the bot and forwards Ahmad's **text** to the controller. Button presses
  (`callback_query`) are not known to reach the brain (the same open gap as the OS question buttons). So the preview uses **signed URL
  buttons** to the brain's own page, which work without the relay. The callback path and `POST /social/decide` stay as second and third
  doors. Cost if wrong: none, since URL buttons need no relay.
- Ruling RR-social-kv: images go in the existing KV, not a new R2 bucket. Volume is under 1 MB per post, and no binding or deploy step is
  added. Cost if wrong: a later move to R2 if volume grows 100x.
- LinkedIn stays disabled until L1 to L5 are done. Facebook stays disabled until M1 to M5 are done. The digest names both every day.
- The `application.name == Instagram` label is unverified until the first live feed read (section 5).
- Deploy is not part of this PR. On deploy: set the secrets above, then `bash os/install.sh` on the Mac to load `com.ebda.os.social-content`.
