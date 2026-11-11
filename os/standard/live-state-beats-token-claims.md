# live-state-beats-token-claims — a signed claim, a caller-supplied key and a status flag are inputs, not authority

tags: [BOTH]
sources: backfill auth/security audit 2026-11-12 (ID-02, TEN-1, WA-2, WA-5)

Four findings in one audit shared a root: a decision was made from a value that was true when it was
written, not when it is used.

1. **Role claims in a token (ID-02).** A `pa: super_admin` claim stayed honoured for the token's
   lifetime after the account was demoted. **Rule:** an elevated claim is honoured only if the live
   account row still grants it, and every role change calls the revocation path (event
   invalidation on every layer; a TTL is not a substitute).
2. **Tenant lifecycle status (TEN-1).** `suspended` was enforced on the storefront but not on the
   admin API. **Rule:** a status that restricts a tenant is enforced by ONE middleware on every
   route family. A suspended tenant is read-only plus billing, with a visible banner in the user's
   language.
3. **Caller-supplied identity keys (WA-2).** A service-binding bridge accepted `buyerKey` and
   `phone` separately and never related them. **Rule:** a derived identifier is recomputed on the
   receiving side from the primary input and compared; never trusted because the caller is
   internal.
4. **Credentials sent to URLs from response bodies (WA-5).** A bearer token followed a URL taken
   from a JSON body. **Rule:** require https and an exact-host allow-list before attaching a
   credential.

**Test:** each rule needs a test that fails on the old code: demote then call with the old token;
suspend then POST a non-billing route; mismatched key and phone; foreign host media URL.
