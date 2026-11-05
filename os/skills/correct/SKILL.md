---
name: correct
description: Use when Ahmad corrects you, a mistake repeats, or a lesson is learned. Encode it in the strongest enforcer (architecture, types, detector, test, hook) before writing prose; keep the rule-to-enforcer map; propose retiring rules whose mistake is now impossible.
---
<!-- ported from cursor/plugins pstack (MIT) correct + principle-encode-lessons-in-structure, merged with CLAUDE.md "dual authorship", memory feedback-stated-rules-need-enforcing-code, ops/encode-lesson.sh, standard/{mutation-proof,gate-integrity}.md; 2026-10-08 -->

# Correct

A rule only in CLAUDE.md or memory is a preference, not a gate: nothing fails when an agent skips it. Assume every future agent sees only the files it opened, copies the nearest example, and takes the shortest path that compiles. Make the mistake impossible there.

## 1. Classify

Fix the instance first. Then name the **class** (rule C: the report is a sample). A class counts once it has happened twice; a first occurrence still gets a memory file + a proposed enforcer. Evidence: `git log`, reverts, review comments, the correction itself. Grep every sibling surface.

## 2. Climb the ladder: stop at the highest rung that works

| Rung | Enforcer | Here |
|---|---|---|
| 1 | Architecture: one owner per state, hidden internals, delete the old way | the repo itself |
| 2 | Types: bad state unrepresentable | tsconfig / Zod at the edge |
| 3 | Lint / detector whose **error names the fix** (file, type or function to use instead) | `ops/encode-lesson.sh` → `ops/detectors/_candidates/` → review → `ops/detectors/` |
| 4 | Test (mutation-proven, `standard/mutation-proof.md`) | the repo's suite |
| 5 | Hook (blocks the tool call) | `ops/hooks/*.sh`, registered by `ops/install-hooks.sh`, declared `# claude-hook:` |
| 6 | Doc / memory, only for judgment calls | memory file + `standard/` |

Say in the reply why each higher rung did not work. If the pattern is already widespread, fail only on *added* occurrences.

## 3. Build the enforcer, then prove it

- Rung 3: **use `ops/encode-lesson.sh <memory-file.md>`** (never hand-roll a second drafter). It writes a *candidate*; review it, run `python3 ops/lib/detector-run.py --repo test --dir <repo> --detectors ops/detectors/_candidates`, then move it to `ops/detectors/`.
- **Prove it fails on the real past mistake** (the commit that made it) and passes on the fix. A check never seen failing is a dead gate (`standard/gate-integrity.md`).
- A hook is not installed until it is registered: run `ops/install-hooks.sh`, then `ops/dead-gate-detect.sh`.
- Exceptions live on the offending line: reason + expiry + Ahmad's approval.

## 4. Dual authorship (both halves, same session)

a. **Memory file** in the global memory root (`feedback-<theme>.md`, roll into an existing theme file, one MEMORY.md line per theme). It must contain the literal sentinel line `indexed in global MEMORY.md` or `dream-standard-drift.sh` never sees it. Re-run the memory pipeline and confirm the file persists.
b. **Foundation PR**: the enforcer (`ops/`) and/or the rubric (`standard/`, cite the slug as `sources:`), plus a row in the map below. The OS does not read memory; no PR means the lesson never reaches it.

## 5. Keep the map

Add a row to `standard/rules/enforcement-map.md` (rule → rung → enforcer → proof). A rule with an empty enforcer cell is a repeat waiting to happen: fix it at a higher rung in the same change.

## 6. Retire, never silently

When a rule's enforcer exists and the mistake can no longer happen, **propose** removing the prose from CLAUDE.md/memory: list the line, the enforcer, the proof. Ahmad approves; you do not delete. Mark the map row `retire-proposed <date>`.

Reply: class + evidence, rung chosen and why not higher, enforcer file, failing-then-passing proof, memory + PR paths, retire proposals.
