# The loop

foundation -> build -> QA -> finding -> foundation. ebda-foundation is the source of truth and the home of this loop.

1. **QA** on the QA store (Amelia Aurum, `1bb14d0e-0cb8-4cb4-b939-e889c4bc2ebc`, ameliaaurum.com + store.ebda.app admin) finds an issue.
   Every pass covers every button, API path, branch and page, at 390/820/1280/1440, admin <-> storefront <-> marketing.
2. **Classify**: UX / money / auth / data / ops / feature. Build priority: money > auth > data > ops > UX.
3. **Check the foundation first**: `design/` (tokens, component rules; present once #20 merges), `design/references/`
   (six DESIGN.md, reference only), `os/standard/`, `docs/RULINGS.md`, the guards.
4. **If the answer is missing, add it to the foundation first**: a token, component rule, backend standard, ruling or guard.
   The finding is not fixed until the rule that would have prevented it exists.
5. **The product consumes it**: themed PR into main (never stacked) with a test that fails on the old code; the drain loop
   merges green PRs; deploy is automatic; confirm the live commit (`/health`) equals the main tip.
6. **Re-verify live** on Amelia (or the live site) before the item moves to CLOSED. A merge is not a deploy, a deploy is not a fix.
7. **Never idle while STILL-OPEN or FOUND is non-empty.** New QA findings go to FOUND in `loop/REGISTER.md`, then step 2.

## How to run: say "loop"

Say **loop** (or "run the loop" / "start the loop") and the controller follows the `ebda-loop` skill (`os/skills/ebda-loop/SKILL.md`, installed to `~/.claude/skills/ebda-loop` by `os/install.sh`). It is NOT the built-in `/loop <interval>` timer skill. One cycle: re-triage STILL-OPEN + FOUND -> dispatch Sonnet builders (money > auth > data > ops > UX) -> merge through the drains + review gate -> deploy verify -> QA on Amelia -> audits on cadence -> alerts -> exit check. It stops only when `loop/exit-check.sh` passes all 6 criteria. Status at any time: `bash os/ops/loop-status.sh` (also on the brain status page when present).
