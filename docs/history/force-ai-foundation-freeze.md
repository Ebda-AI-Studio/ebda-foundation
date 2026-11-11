# Freeze of the predecessor AI OS repository

On 2026-11-05 the predecessor repository `ForceAI-KW/force-ai-foundation` was frozen at tag `final-before-ebda`, which points at commit `1d48b9f`. Its OS tooling is ported into `os/` of this repository (Ruling FDN-OS-1); nothing further lands in the old repository.

## Open OS PRs at the freeze

These nine PRs were open on the predecessor when it froze. They are to be folded into the port (each is re-applied to the ported `os/` tree, or dropped with a ruling).

| PR | Branch | Head | Title |
|---|---|---|---|
| #280 | `chore/ebda-org-move` | `41e53008f` | chore(ops): point ebda repo slugs at the Ebda-AI-Studio org |
| #279 | `fix/guard-rebuild-backoff` | `3a99ba43e` | fix(ops): ci-runner-guard rebuild loop - verify kernel+docker, block after faile |
| #278 | `fix/hygiene-orphan-tests-dirs` | `1952cb1ac` | fix(ops): hygiene sweep no longer reaps tracked __tests__ dirs inside a worktree |
| #276 | `feat/ebda-2026-10-lenses` | `a101b7dd7` | feat(audit): Ebda 2026-10 lens pack + graded standards (mirror of mypovonai-lear |
| #275 | `feat/guest-autoheal-u4` | `f070c95e4` | feat(ops): auto-heal sequence with evidence, verification and a 2 per 24h budget |
| #274 | `fix/start-uses-fsck-if-dirty` | `63d280785` | fix(ops): automated umbra start carries --fsck-if-dirty when supported |
| #264 | `feat/usage-sentinel` | `fa2b9f8dd` | feat(ops): usage sentinel - stale usage is UNKNOWN, >=80% writes fanout-stop (S2 |
| #263 | `fix/merge-gate-rebase-needed` | `313786d98` | feat(merge-gate): rebase needed on conflicts; cancelled is not failing |
| #262 | `fix/umbra-guest-integrity` | `8c0c2036b` | docs(standard): umbra-guest-integrity |
