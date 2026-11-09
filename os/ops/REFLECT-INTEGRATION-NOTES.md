# REFLECT integration note — classify.sh change needed (NOT made in this PR)

`~/.claude/scripts/remediation/classify.sh` is standalone (lives outside this repo,
under `~/.claude/scripts/remediation/`, NOT copied by `ops/install.sh`) and is the
**live running file** — editing it here would have no effect on production and risks
drifting the worktree's understanding of it out of sync with what's actually deployed.
This PR does not touch it. Whoever finalizes/merges this PR should hand-edit it once.

## The one-line change

`dream-reflect.sh` emits findings with `class: "reflect-unenforced-lesson"`. Per the
REFLECT design law (detectors flag PATTERNS, not verified defects — REFLECT proposes,
never auto-applies), every one of its findings is `autofixable: false`, but
`dream-act.sh`'s Tier A/B/C routing is driven by `classify()`'s CLASS_A/CLASS_B/EXCLUDED
verdict, not by the finding's own `autofixable` flag alone — so `reflect-*` classes
should be explicitly routed to `EXCLUDED` (human-only) for defense in depth, consistent
with how `classify.sh`'s own comment states its philosophy: "Over-inclusion here is
fail-SAFE: the worst case is an extra human review, never an unreviewed auto-merge."

Add `*reflect*` to the `EXCLUDED` substring-glob case in `classify()`:

```bash
classify() {
  case "$1" in
    *money*|*payment*|*auth*|*session*|*rls*|*polic*|*migration*|*secret*|*security*|*credential*|*env*|*deploy-config*|*reflect*)
      echo EXCLUDED ;;
    lockfile-drift|dep-bump|dep-sync|format|lint-autofix)
      echo CLASS_A ;;
    *)  # everything else is a code change -> Class B (still fully gated + human-reviewable)
      echo CLASS_B ;;
  esac
}
```

(Just the one line — add `|*reflect*` to the first case arm's glob list.)

## Why this matters even though autofixable is already false

`dream-act.sh` already respects `autofixable` for its own Tier A/B/C split (see
`ops/dream-act.sh` around the `--- Tier A: autofixable + safe-tier ---` block), so a
`reflect-unenforced-lesson` finding was never going to auto-merge through THAT path.
The `classify.sh` change is belt-and-suspenders for a second consumer: if any other
Whisky AI OS subsystem (present or future) reads `dream-findings.json` and asks
`classify.sh` "is this class safe to automate," `*money*`-style substring exclusion is
the single source of truth it consults — without this line, a future caller that
doesn't separately check `autofixable` could treat `reflect-unenforced-lesson` as a
plain CLASS_B code change instead of a "this proposes changing a STANDING RULE /
process, always human-only" finding.
