# navigation-integrity — a screen JS thinks is still presented is a dead app

tags: [BOTH]
sources: feedback-native-stack-beforeremove-swipe-dismiss; feedback-sense-audit-real-world-logic (device-test source: the owner on a real iPhone found what ~5,000 green tests did not); a marketplace launch audit (the fix + its source-scan guard; see history)

An owner opened a post wizard (an iOS modal), advanced a step and swiped it down. The app
"became unresponsive": animations ran, taps registered, nothing navigated. The wizard vetoed
removal with a raw `navigation.addListener('beforeRemove', e => e.preventDefault())`.
React Navigation's native-stack only blocks a swipe-dismiss through `usePreventRemove`
(`preventedRoutes`); with the raw listener the modal is dismissed **natively** while JS still
holds `/post` on the stack. The next push re-presents the ghost modal instead of navigating,
and every later navigation is dead.

**The rule:** *a screen is only ever kept open by the navigator's own prevent-remove API, and
every blocked screen has an explicit way out.*

**Tradeoff:** a hook and a close button, against a launch-day "the app is frozen" that no
unit test can reproduce (the JS state machine is internally consistent; the native layer is
what disagrees).

## 1. The failure mode

1. A modal/screen must not be dismissed mid-flow (unsaved wizard, KYC upload, payment).
2. The author vetoes it with a `beforeRemove` listener + `preventDefault` — correct on web and
   Android back, **ignored by the iOS native swipe-dismiss gesture**.
3. Native removes the view, JS keeps the route. Taps still "work" (on the ghost), animations still
   run, navigation silently targets a stack the user cannot see.
4. Typecheck, lint, unit and JS-level E2E all pass; only a real device (or a Maestro flow that
   swipes down then pushes) shows it.

## 2. What to check

| # | Criterion | Solid (grade 2) | Gap detection | Severity |
|---|---|---|---|---|
| 1 | No raw `beforeRemove` veto | Blocking a dismiss uses `usePreventRemove(cond, cb)`; no `addListener('beforeRemove', ...)` that calls `preventDefault` | grep RN/Expo source for `beforeRemove` within a few lines of `preventDefault`; any hit outside tests is the gap | High |
| 2 | Blocked screens have an explicit close | Every prevent-remove screen has a visible close control that runs confirm-then-dismiss, and the swipe gesture is disabled or confirm-gated past step 0 | read each `usePreventRemove` screen for a close/cancel control; none = the user's only exit is the vetoed gesture | Medium |
| 3 | A guard test keeps the pattern out | A source-scan test fails if raw `beforeRemove`+`preventDefault` reappears | look for a test that greps the app source for it | Medium |
| 4 | The flow is driven on a device build | A flow (Maestro/Detox) opens the modal, advances, swipes down, pushes another screen and asserts it rendered — and was seen to FAIL on the old build first | look in `.maestro/`/e2e for a dismiss-then-navigate flow | Medium |

## 3. What good looks like

    usePreventRemove(dirty, ({ data }) => confirmDiscard(() => navigation.dispatch(data.action)))
    // header: <CloseButton onPress={() => confirmDiscard(navigation.goBack)} />

## 4. Where it is graded

React Navigation / expo-router apps (native-stack). N/A for web-only repos. "UI responds but
navigation is dead" is the symptom to chase here before suspecting the deep-link handler.
Probe criterion 1 is mechanical; 2-4 are judge-graded.
