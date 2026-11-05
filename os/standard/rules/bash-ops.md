# bash-ops — Language/Framework Rule Pack

tags: [BOTH]
scope: shell scripts, ops tooling, launchd/cron jobs, CI shell steps, any `.sh` file or inline Bash-tool command
sources: `../cicd.md`, `../testing.md` (criteria 7–8, 13), MEMORY.md feedback-bash-tool-shell-gotchas, feedback-jest-module-setinterval-leak, feedback-jest-ci-hang-debugging-and-root-causes, feedback-ci-integration-ephemeral-postgres-not-shared-neon, feedback-blast-radius-sweep-on-every-change

## Must Always
- Remember the Bash tool on macOS runs **zsh**, and zsh arrays are **1-indexed** (`F=(*.mov); echo "${F[1]}"` is the first element, not `${F[0]}`). A glob that reports `count: 1` but reads back empty via `${F[0]}` is this trap, not a missing file. Prefer a shell-agnostic `for f in glob; do F="$f"; done` loop over indexed array access when a script might run under either bash or zsh.
- Quote every path variable (`"$F"`, `"$path"`) — macOS filenames (Screen Recording exports especially) can contain non-ASCII spaces (narrow/no-break space, not U+0020) that make a hand-typed literal path fail with "No such file or directory" even though `ls` clearly lists the file. Reference such files via a glob or wildcard, never a retyped literal path.
- Give every CI job an explicit `timeout-minutes` (lint=5, typecheck=10, build=15, unit=10, integration=15, E2E=20, audit=5) — a leaked Jest/vitest handle can otherwise hang a runner 30–45 minutes past what the test output shows.
- Run Prisma `db:generate` BEFORE any typecheck step in CI — without it, `tsc` reports ~300–400 phantom errors from missing `@prisma/client` types.
- Split the CI audit gate: prod deps zero-tolerance (`npm audit --audit-level=low --omit=dev`), dev deps gated at `high` (unfixable transitive tooling vulns are common and shouldn't block ship).
- Add a `notify-failure` job that fires on `failure() && main && push` via a Telegram bot token + chat-id secret pair, pinned to `runs-on: ubuntu-latest` even when the rest of the pipeline is self-hosted (fail-open — the alert must survive a dead self-hosted runner).
- Use ephemeral, per-run containers for integration tests (`postgres:17`, `redis:7-alpine`) — never share state with a persistent dev/staging database. Bind non-default host ports (5544/6390 not 5432/6379) so a local service running on the default port doesn't silently shadow the container.
- Guard every destructive reset (`TRUNCATE`, `db push --force-reset`, bulk `deleteMany`) with a host/db-name check that refuses unless the target is a disposable localhost/container DB — this single guard has prevented a TRUNCATE from wiping a production database via a misconfigured `.env`.

## Must Never
- Never mask a Jest hang with `--forceExit` — it only fires AFTER the run completes; a request/test that hangs mid-run is completely unaffected by the flag. Remove it from any pre-push hook or CI command and fix the actual leaked handle (module-level `setInterval`/`setTimeout`, an unclosed Prisma client, a BullMQ `Queue` connection).
- Never run a `grep`/audit/sweep command through `| head` when it's meant to be a blast-radius or completeness sweep — truncating the output means you silently miss hits past the cutoff and report "found + fixed N" against an incomplete list.
- Never assume `bash` semantics (0-indexed arrays, certain glob behaviors) when a script might execute under the Bash tool's zsh, or vice versa — write array/loop logic that's shell-agnostic instead of tool-specific.
- Never leave a long foreground `sleep` in an automated script when a poll-until-condition loop or the harness's background/Monitor pattern is available — foreground sleeps in interactive tooling are blocked/wasteful; use `until <check>; do sleep 2; done` patterns for polling instead of a single long sleep.

## Patterns
- **Audit recipe for module-level timers** (find every Jest-hanging candidate before it hangs CI):
  ```bash
  grep -rn --include="*.ts" --include="*.tsx" --include="*.js" \
    -E "^[[:space:]]*set(Interval|Timeout)\(" src/ apps/ 2>/dev/null
  ```
  Every hit needs an exported handle + a `clearInterval`/`clearTimeout` in a teardown hook (`jest.setup.ts` `afterAll`), or a documented justification.
- **Jest CI-hang bisection playbook** (zero output, job just times out): run each suspect test file standalone with a watchdog (`npx jest <file> & ` + poll `kill -0` up to ~35s); `--runInBand` stalling at byte 0 = hang at module-load or the first suite's setup (output is buffered per-suite); inject a per-test `beforeEach`/`afterEach` ENTER/EXIT trace to `process.stderr` to pin the exact hanging test; `sample <pid> 2` (macOS) to distinguish a 0%-CPU wait (parked on a never-resolving promise/handle) from an actual spin loop.
- **Blast-radius sweep as a single grep pass**, run once at the end of a logical change-set (not per tiny edit): grep every touched identifier (renamed symbol, rotated host/ID, new env key) across code + configs + `.github/workflows/*` + launchd/cron plists + monitoring/alerting scripts + docs + `.env.example` + sibling repos, in one pass, before calling the change done.

## Traps
- `count: 1` from a glob assignment into a zsh array, followed by an empty read from `${F[0]}`, is the 1-indexing trap — not a missing-file bug. Don't retype the path; fix the index.
- A `cd` inside one Bash-tool compound command does not persist to the next call — the working directory resets between calls. Use absolute paths rather than relying on an earlier `cd`.
- A CI integration job that's chronically red only on Linux/CI (green locally, green per-file, red only in the full run) is almost never N separate bugs — it's shared-state pollution across tests. Move to a per-run ephemeral container + a hard per-file `TRUNCATE ... RESTART IDENTITY CASCADE` reset instead of whack-a-moling individual test cleanups.
- A post-job hook on a self-hosted runner that can exit non-zero will red an ENTIRE job at the "Complete runner" step even after every real step (lint/build/test) passed — write any cleanup hook `set +e ... || true ... exit 0` so housekeeping never blocks a merge.

Cross-links: `../cicd.md` (the full canonical CI/CD workflow shape), `../testing.md` (five-layer testing + teardown discipline), `node-express.md` (the Jest-hang root causes at the application-code level), `prisma-postgres.md` (ephemeral Postgres + RLS role mirroring for CI).
