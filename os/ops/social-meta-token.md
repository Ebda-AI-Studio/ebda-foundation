# Facebook Page tokens for the brain (`social-meta-token.sh`)

This turns a short-lived Graph Explorer user token into Page tokens that never expire, one each for the **Ebda AI Studio** and **Whisky 11**
Pages. It stores them as the brain secret `SOCIAL_FACEBOOK`, with a base64 copy in Keychain `ebda-os-social-facebook`. No token or secret
is printed or passed as a command argument, and the clipboard is cleared after each read.

App: **Ebda AI Studio Social** (id `1733132125094316`, Live). Plan: `docs/plans/2026-11-11-social-posting.md` section 9.

## Steps (about 3 minutes)

1. **App Secret, needed only once.** Go to https://developers.facebook.com/apps/1733132125094316/settings/basic/, click **Show** next to
   App Secret, and copy it. Then run:
   ```
   ! bash ~/Desktop/projects/Ebda-AI-Studio/internal-projects/ebda-foundation/os/ops/social-meta-token.sh --save-app-secret
   ```
2. **User token.** Go to https://developers.facebook.com/tools/explorer/ and set **Meta App** = Ebda AI Studio Social and **User or Page** =
   User Token. Add the permissions `pages_show_list`, `pages_read_engagement`, `pages_manage_posts`, and also `pages_read_user_content`
   (see below). Click **Generate Access Token**, log in, and in the Pages step tick **both** Pages. Copy the token, then run:
   ```
   ! bash ~/Desktop/projects/Ebda-AI-Studio/internal-projects/ebda-foundation/os/ops/social-meta-token.sh
   ```
   Add `--dry-run` first if you want to see the check without storing anything.

The script then:
- exchanges the user token for a long-lived one (`fb_exchange_token`);
- reads `/me/accounts`, picking the Pages whose names contain "ebda" and "whisky". If a name doesn't match, set
  `SOCIAL_FB_PAGE_EBDA=<id>` or `SOCIAL_FB_PAGE_WHISKY11=<id>`;
- checks each Page token with `debug_token`: it must be valid, have `expires_at = 0` (never expires) and `pages_manage_posts`, and you must
  hold CREATE_CONTENT on the Page;
- runs `wrangler secret put SOCIAL_FACEBOOK --name ebda-os-brain` on the personal Cloudflare account (`OS_CF_ACCOUNT_ID`).

If only one Page passes, it stores that one and names the problem with the other.

## Notes

- **`pages_read_user_content` is not in the app's use case yet.** Without it the brain cannot read the Page feed. That feed read is what
  keeps OS posts 3 h away from your Instagram shares, and what lets the digest list those shares. Posting still works. To add it, go to the app >
  **Use cases** > Manage everything on your Page > **Customize** > add `pages_read_user_content`, then generate the token in step 2. The
  script's output says `feed read: yes/NO` for each Page.
- The brain only uses `SOCIAL_FACEBOOK` after the social-posting PR (#12) is merged and deployed. Storing it earlier is harmless.
- These Page tokens stop working only if your password changes, you lose your Page role, or the app is removed. The brain then sees Meta
  error 190 and alerts you; re-run step 2.
- Offline test: `bash os/ops/tests/social-meta-token.test.sh` (Meta, Keychain and Cloudflare are faked).
