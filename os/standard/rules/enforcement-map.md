# enforcement-map — Rule → Enforcer Table

tags: [BOTH]
scope: every standing rule the OS cares about; maintained by the `correct` skill (`skills/correct/SKILL.md`)
sources: pstack `correct` (MIT, see `skills/THIRD-PARTY.md`), `feedback-stated-rules-need-enforcing-code`

A rule with an empty Enforcer cell is a preference, not a gate. Rungs: 1 architecture · 2 types ·
3 lint/detector (error names the fix) · 4 test · 5 hook · 6 doc/memory only. When the mistake can
no longer happen, mark the row `retire-proposed <date>` and ask Ahmad; never delete prose unasked.

| Rule | Rung | Enforcer | Proof it fails on the real mistake |
|---|---|---|---|
| Never `--no-verify` on git | 5 | `ops/hooks/block-no-verify.sh` (PreToolUse) | `ops/lib/__tests__/hook-guards.test.sh` |
| `git add` specific paths, never `-A`/`.` | 5 | `ops/hooks/block-git-add-all.sh` (PreToolUse) | `ops/lib/__tests__/hook-guards.test.sh` |
| Root checkouts stay on main read-only (no commit there) | 5 | `ops/hooks/block-root-checkout-commit.sh` (PreToolUse) | `ops/lib/__tests__/hook-guards.test.sh` |
| Subagents set `model` (advisory, never blocks) | 5 | `ops/hooks/warn-agent-no-model.sh` (PreToolUse) | `ops/lib/__tests__/hook-guards.test.sh` |
| One sweep/watcher at a time; `--help` runs nothing; unknown flag = exit 2; hung `du`/`df` = UNKNOWN, no delete | 4 | `ops/lib/single-instance.sh`, `ops/lib/args.sh` | `ops/tests/single-instance.test.sh` |
| CI failure / queued-forever / unreadable CI reaches Ahmad from outside the fleet | 3 | `ops/ci-alert.sh` (launchd, 5 min) | `ops/tests/ci-alert.test.sh` |
| GNU `stat -c` before BSD `stat -f` | 4 | `ops/tests/no-bsd-first-stat.test.sh` | the test itself |
| Do not edit protected config | 5 | `ops/hooks/protect-config.sh` (PreToolUse) | `ops/lib/__tests__/hook-guards.test.sh` |
| Declared hooks must be registered | 4 | `ops/dead-gate-detect.sh` | `ops/lib/__tests__/dead-gate-hooks.test.sh` |
| Repos live in a business-folder slot | 3 | `ops/projects-layout-check.sh` | `ops/tests/projects-layout.test.sh` |
| GitHub Advanced Security stays off | 3 | `ops/ghas-guard.sh` (weekly) | `ops/lib/__tests__/ghas-guard.test.sh` |
| GitHub Actions pinned to SHA | 3 | `ops/pin-actions.sh` | `ops/lib/__tests__/pin-actions.test.sh` |
| No GNU `gdate` in OS scripts | 4 | `ops/tests/no-gdate.test.sh` | the test itself |
| Skill files are small and named for their dir | 4 | `ops/lib/__tests__/skills-lint.test.sh` | the test itself |
| Say "found + fixed N" for every sweep (rule D-GATE) | 6 | none yet: `skills/blast-radius` is prose | open: candidate for a Stop-hook check |
