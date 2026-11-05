> History: this client launch-readiness pack is kept as the source of lenses 39-41 (navigation-integrity, state-transition-integrity, real-world-sense). It names a predecessor-fleet client product, so it lives under docs/history/, not os/audit/lenses/.

# gcc-horse-market launch-readiness pack — 2026-10-07

Source: one day on `ForceAI-KW/gcc-horse-market` (PRs #197-#209). Owner device testing on a real
iPhone plus one four-lens read-only "does it make sense" audit (reports: `sense-audit/{geo,
auth-roles,money-lifecycle,prod-data}.md`, `device-audit-2026-10-07.md`). Memory:
`feedback-sense-audit-real-world-logic`, `feedback-native-stack-beforeremove-swipe-dismiss`,
`feedback-lockfile-regen-must-match-deploy-node-version`.

Fleet status: applied to gcc-horse-market only (it is the source). Still to run: FWB, Ebda,
Force-Media-CRM, menus/landings.

**P1 - Dead navigation after a swipe-dismiss.** Scenario: open the post wizard (iOS modal),
advance a step, swipe it down; animations run, taps register, nothing navigates.
`navigation.addListener('beforeRemove', e => e.preventDefault())` is ignored by the native
swipe, so the view is gone and JS still holds the route.
-> Lens `navigation-integrity`. Check: `grep -rn "beforeRemove" src app | grep -v test`, then read for `preventDefault`.

**P2 - A transition that assumes the state it was shown.** Scenarios: double-click approve = two
audit rows and two pushes; restore on a deleted draft published it; suspend twice demoted
listings twice; resubmitting KYC while `in_review`; admin page badge = the latest-updated
profile, next to the wrong role chip.
-> Lens `state-transition-integrity`. Check: in every approve/review/restore/grant/suspend
handler, is the current state in the `where`?

**P3 - Correct code, nonsense product.** Scenarios: a UAE vet offered for a Kuwait horse (no
country filter on the services endpoint); "price collected in KWD" under a price never collected;
guest told "verify your ID" (KYC prompt before sign-in); seller offered the bid button on their
own auction; cancel while payment pending kept the money; an ended auction shown live; AI read
"0%" for a read that never ran; listing video not seekable (no Range/206).
-> Lens `real-world-sense` (four sub-lenses: location pairing, gate order, money+lifecycle,
identity reuse). Mostly judge-graded; probes only for the mechanical slices.

**P4 - Lockfile from a newer npm than CI.** Scenario: lock written by a newer npm major than the
Node CI pins; CI `npm ci` rejects with "Missing: X from lock file" (FWB #2524).
-> Extends `deploy-verify` criterion 8 (`engines`/`packageManager` vs workflow `node-version`).

**Not lenses (infra, fixed in ops, #206):** umbra guard restarting every runner on one dead
listener; the throttle failing open after `--wait-deadline-sec`.
