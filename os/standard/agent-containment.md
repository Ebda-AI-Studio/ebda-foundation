# agent-containment — What an Unattended Agent May Not Do, and the Code That Stops It

tags: [BOTH]
sources: reference-harness-extraction-2026-09.md, feedback-stated-rules-need-enforcing-code.md, ECC `scripts/hooks/config-protection.js:24-63` + `scripts/hooks/block-no-verify.js`, Auto-Company `auto-loop.sh:131-179`, deepseek-harness `packages/subprocess/subprocess/src/index.ts:46,64-76`

## What "solid" looks like
For every rule about what an agent must not do, there is a named file that makes it impossible, and a named test that proves the block fires. A rule that lives only in `CLAUDE.md` is a preference: it holds while the agent is paying attention and fails silently in exactly the sessions where it matters most — the unattended ones, where nobody is watching the transcript.

## Why this lens exists
A source-level review of five agent harnesses on 2026-09-04 found that four of the five had independently built mechanisms preventing an agent from faking success — a `--no-verify` blocker, a lint-config write blocker, an eval whose expected values come from a parser that shares no code with the generator, a `.gitignore` snapshot-and-restore, a credential scrub before every child spawn. This OS had written the sentences and none of the code. It is the strongest of the five at *detecting* problems and was the weakest at *preventing an agent from lying about them*.

Two live examples of the cost, both measured the same day:
- `ops/self-eval-gate.sh` existed, documented itself as a Stop hook, and was **registered nowhere**. It had never fired.
- `ops/dead-gate-detect.sh` — the OS's own dead-gate detector — had **no hook-registration check at all**, so it was structurally blind to the case above.

## Criteria
| # | Criterion | Solid (grade 2) | Gap detection | Severity |
|---|---|---|---|---|
| 1 | Hook bypass is blocked, not discouraged | `git commit/push --no-verify`, `-n` on a verifying subcommand, and `-c core.hooksPath=` are denied at PreToolUse | `ops/hooks/block-no-verify.sh` present and registered; `hook-guards.test.sh` green | High |
| 2 | The blocker has no false positives | `git commit -m "…--no-verify…"` and `git log -n 5` are allowed. A guard that trips on legitimate commands gets disabled, and a disabled guard is worse than none | the allow-cases in `hook-guards.test.sh` | High |
| 3 | Gate configs cannot be weakened mid-run | Editing an **existing** eslint/prettier/biome/ruff/tsconfig/vitest/gitleaks/lefthook/`.gitignore` is denied; **creating** one is allowed | `ops/hooks/protect-config.sh` present and registered | High |
| 4 | Config guards fail closed | An unstattable path denies rather than being treated as absent | the `unstattable path fails CLOSED` case | Medium |
| 5 | Every declared hook is registered where it runs | Each hook script carries `# claude-hook: <Event>`, and each declaration matches a registration in `~/.claude/settings.json` | `ops/dead-gate-detect.sh` reports declared-but-unregistered hooks | Critical |
| 6 | A missing or unparseable settings file is a FINDING | Absent settings = every declared hook is dead; unparseable = hook state UNKNOWN. Neither reads as clean | `dead-gate-hooks.test.sh` cases 5 and 6 | High |
| 7 | Registration refuses to point at nothing | `ops/install-hooks.sh` will not register a hook whose script is absent, and will not overwrite a settings file it cannot parse | `install-hooks.test.sh` | High |
| 8 | Credentials never reach a child process | Variables matching `KEY\|PASSWORD\|SECRET\|TOKEN\|CREDENTIAL` are stripped before any spawn, with an explicit allow-list for deliberate passthrough | `ops/lib/subprocess.sh` + `subprocess.test.sh` | High |

## The registration contract
A hook is installed in two steps and both are required:
1. `ops/install.sh` copies `ops/hooks/*.sh` into `~/.claude/scripts/hooks/`.
2. `ops/install-hooks.sh` registers them in `~/.claude/settings.json`.

Step 1 without step 2 is the dead-gate bug. The marker line `# claude-hook: <Event>` in each script is what makes the omission detectable rather than invisible — `dead-gate-detect.sh` compares declarations against registrations on every run.

## OS-level sandboxing — adopted 2026-09-04

`vendor/landlock-run` (BSD-3-Clause, from deepseek-harness at
`76fda729799fe9b3848dbe2c211d4b231032b81e`, byte-identical, provenance in
`vendor/landlock-run/VENDOR-PROVENANCE.md`) installs a Landlock ruleset on itself and
`exec`s the wrapped command. The ruleset is inherited across `execve`, so the command
and everything it spawns run confined while the caller stays unrestricted. Landlock is
an independent syscall family — no root, no user namespaces, no bwrap — which is why it
is the rung available on a Linux host.

This was originally deferred as unverifiable while the fleet was down. It was then
verified in a Linux container instead, which is a better test anyway because it is
reproducible: `ops/lib/__tests__/sandbox-linux.sh`, run under Docker, builds from
`vendor/` and asserts the kernel actually denies a write outside the allow-list.
Result on 2026-09-04, kernel 6.12.76: `landlock: fully enforced`; write inside `--rw`
succeeds; write outside is denied and the file confirmed absent; reads under `--ro /`
still work.

| # | Criterion | Solid (grade 2) | Gap detection | Severity |
|---|---|---|---|---|
| 9 | Unattended agent shell is filesystem-confined | Commands executed by `dream-fix`/`dream-act`/`self-heal`/`remediate` on a Linux guest run through `sandbox_run`, with write access only to the working tree | grep those scripts for `sandbox_run`; `sandbox_available` returns 0 on the guest | High |
| 10 | The sandbox refuses rather than degrades | On a host that cannot enforce (macOS, or a guest missing the binary) `sandbox_run` exits 70 and does NOT run the command. A sandbox that silently does nothing on half the fleet reads as protection while providing none | `sandbox.test.sh` — the refusal cases | Critical |
| 11 | The builder refuses to install a non-enforcing binary | `ops/build-landlock.sh` runs `--probe` before installing and aborts if the kernel does not enforce | run it on a kernel without `CONFIG_SECURITY_LANDLOCK` | High |
| 12 | `/dev` is granted, deliberately | `--ro /` alone denies writing `/dev/null`, so nearly every real command fails in a way that looks like the command is broken rather than confined. `sandbox_run` grants `/dev` and says why | grep `sandbox.sh` for the `/dev` grant and its rationale | Medium |

**Not yet done:** the `dream-*` and `self-heal` call sites are not routed through
`sandbox_run` yet — the helper, the vendored launcher, the builder and the proof exist,
the adoption does not. That is a change to live unattended automation and wants the
fleet up so it can be watched on first run.

## Evidence (filled during audit, per repo)
- ebda-foundation: criteria 1-7 live as of 2026-09-04. Criterion 8 (credential scrub) pending. Landlock: launcher vendored, wrapper + builder written, functionally proven on Linux; call-site adoption pending the fleet.
