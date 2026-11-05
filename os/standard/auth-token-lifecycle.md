# auth-token-lifecycle — session and reset-token credentials outlive the event that should kill them

tags: [BOTH]
sources: reel lens pack `audit/lenses/reel-lenses-2026-09.md` L21 (session fixation, `DdgxTr7AcvO`),
L23 (reset-token expiry, `DdeMk-bFdui`) — both `@mattmurphyai`, watched 2026-09-22

## What "solid" looks like

Two credentials — the session identifier and the password-reset token — are treated as having
a lifetime shorter than the event that created them, not a lifetime that only ends when
something else overwrites the row. A session id issued before login is dead the instant login
succeeds. A reset link is dead the instant it is used once, or the instant the password changes
by any other path, whichever comes first — and it was never going to be valid past 15 minutes
regardless.

Both failures share a shape: the credential keeps working after the event a reasonable user
believes ended it, silently, with no error and no log line, because nothing ever re-checked
whether it should still work.

## 1. Session fixation

An attacker who can set or observe a session identifier before a victim authenticates — a
shared/public terminal, a crafted link that plants a cookie, a session id readable in a URL —
can adopt that same session the moment the victim logs in, if the identifier itself never
changes at login.

## 2. Reset-token lifetime

A password-reset token that has no expiry, or that remains valid after the account's password
has since changed by any route, is a standing way back into the account — discovered the
moment an old email is searched or an old link is clicked, months later.

## 3. What to check

| # | Criterion | Solid (grade 2) | Gap detection | Severity |
|---|---|---|---|---|
| 1 | Session id regenerated on login | `req.session.regenerate()` (or the framework/provider equivalent) is called on every successful authentication, before any session data is written | `grep -rn "session\.regenerate\|regenerateSession\|\.regenerate(" apps/api/src --include=*.ts`; a login handler that sets session data with no regenerate call in the same path is the finding | Critical |
| 2 | Session id regenerated on privilege change | Re-auth, MFA completion, and role/permission upgrades also regenerate the session id, not only the initial login | trace each privilege-change handler for the same regenerate call used at login | High |
| 3 | Session cookie flags | `Secure`, `HttpOnly`, `SameSite` (`Lax` or `Strict`) all set on the session cookie | grep session/cookie config for `secure:`/`httpOnly:`/`sameSite:`; flag any explicitly `false` or absent in a prod config | High |
| 4 | Reset token expires ≤15 minutes | The token (JWT `exp` claim or a stored row with an expiry column) is rejected once its window passes | `grep -rn "resetToken\|reset_token\|passwordResetToken" apps/api/src --include=*.ts -A8 \| grep -inE "expir\|ttl"`; no expiry check reached in that window is the finding | Critical |
| 5 | Reset token single-use | The token is invalidated (row deleted, `usedAt` set, or JWT `jti` denylisted) immediately on successful redemption, before the new password is confirmed to the caller | grep the reset-completion handler for a consume/invalidate step; a handler that only checks expiry and never marks the token used is the finding — it can be replayed until it expires | Critical |
| 6 | Reset token invalidated on any other password change | Any successful password change (self-service settings change, admin reset, OAuth-linked account change) invalidates every outstanding reset token/link for that account, not only the one used | grep every password-change code path (not just the reset-completion one) for a "revoke outstanding reset tokens" step; a settings-page change that leaves an old emailed link alive is the finding | High |
| 7 | Reset request rate-limited | Issuing new reset tokens is rate-limited per account (reel's figure: 3/hour), Redis-backed per `cache-ratelimit.md` crit 1 | grep the "forgot password" request endpoint (not just the completion endpoint) for a rate-limit middleware | Medium |

## 4. What good looks like

Login calls `regenerate()` before it writes anything to the new session. A reset token is a
row with an expiry and a `usedAt` column, or a JWT whose `exp` is enforced before any claim is
trusted; either way, completing a reset — by any route — makes every other outstanding token
for that account fail on its next check, not merely its own row.

## 5. Where it is graded

Any repo that mints its own sessions (cookie- or JWT-based) and/or offers self-service password
reset. Where an external IdP fully owns session lifecycle (Auth0, Clerk, Supabase Auth session
rotation), criteria 1–3 are the IdP's responsibility to verify against its own docs rather than
grep the app — record which, and confirm rotation-on-login is the IdP's documented default
rather than assumed.
