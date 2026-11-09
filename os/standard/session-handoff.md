# session-handoff — lossless session continuity + context hygiene

Every working session keeps a **`handoff.md`** so a `/clear`, a fresh session, or an auto-compaction never loses working state. It is **per session**: `<repo>/.handoff/<session-id>.md` inside a repo, else `~/.claude/handoff/<session-id>.md` — so sessions started in `~`/scratch dirs (non-repo) resume too, and **two parallel sessions can never overwrite each other**. It is the bridge that makes clearing the chat *early and often* safe — which keeps each session sharp instead of degrading against the context wall. Enforced by the OS (`ops/handoff.sh` + two hooks + a statusline badge), not by memory alone.

**Tradeoff:** one local scratch file per active repo (or one global one) + a habit of flushing before clearing — cheap insurance against the expensive failure mode (a long, degraded thread that has to be reconstructed from scratch after a compaction eats the plan).

## The file — 5 sections, always present
`<repo>/.handoff/<session-id>.md`, or `~/.claude/handoff/<session-id>.md` for non-repo sessions (**local-only, gitignored, never committed**; per-machine/per-thread working state that persists across sessions):
1. **Goal** — what this thread is ultimately trying to achieve.
2. **Current state** — where things stand now (branch, what's deployed, what's broken).
3. **Done** — completed + verified this session.
4. **In progress** — started, not finished; enough detail to resume mid-task.
5. **Left to do** — remaining steps, in order.

Create at the start of real work; update *as you go* (not only at the end) so it's never stale.

## The 40% rule
When context drops to **~40% remaining (≥60% used)**, stop, flush the latest into `handoff.md`, then tell Ahmad it's safe to `/clear`. The next session sees a menu of handoffs and asks which one to resume. `/clear` is **Ahmad's action** — no hook can self-clear a session; the OS's job is to keep `handoff.md` current and *surfaced* so the clear loses nothing.

## OS wiring (`ops/handoff.sh`, installed to `~/.claude/scripts/`)
- **SessionStart hook** → `handoff.sh session-start`: ensures THIS session's file exists (silently, never clobbers), then lists up to 8 **other** sessions' filled handoffs (date + first line of `## Goal`, path) as `additionalContext` — a menu, never the content. The model reads none on its own; if the request continues one, or Ahmad asks to resume, it asks which and reads only that file. Blank templates and its own file are never listed. The text names this session's own path, so the model writes there and never into another session's file.
  **Why a menu (2026-10-08, Ahmad).** It used to inject the newest other session's handoff whole. Sessions in one dir do different work, so newest ≠ relevant: an OS-audit session was handed a 71 KB Ebda handoff (~18k tokens) it never needed.
- **PreCompact hook** → `handoff.sh precompact`: the context-wall backstop — reminds to flush **In progress / Left to do** before the auto-compaction summary happens.
- **statusline.sh** → shows a red `⚑HANDOFF` badge at ≥60% context used (=40% remaining): the live 40% nudge.

Path resolution (`ops/lib/handoff-paths.sh`): `<repo>/.handoff/<session-id>.md` inside a git repo, else `~/.claude/handoff/<session-id>.md` (so `~`/scratch/transient sessions still resume — this closed the original gap where non-repo sessions silently no-op'd). The files are **gitignored, never committed** — per-session working state, so committing would churn commits and leak into every PR.

**Why per-session (2026-08-26).** It used to be ONE shared path per project. Two Claude sessions ran in parallel, both started outside a repo, so both resolved to `~/.claude/handoff.md`; the second session's write destroyed the first's entire working state, silently and with no error. `handoff.sh` does **not** write handoff content — the model does, with Write/Edit — so "detect and refuse to clobber" has no writer to guard. The only fix that holds is that two sessions never resolve to the same path.

The pre-2026-08-26 single-file location is still **read** for resume, so no existing handoff is stranded by the change. Other sessions' handoffs are pruned after 14 days so the directory cannot grow without bound.

## Subagents and Remote Control (2026-10-25)
Subagents inherit the controller's session id, so a subagent writing `<session-id>.md` overwrote the controller's state.
**A subagent writes `~/.claude/handoff/<session-id>-<role>.md`** (e.g. `...-migration.md`). `ops/hooks/block-handoff-clobber.sh`
(PreToolUse) denies a write to another session's handoff and a subagent's write to the bare controller file
(`worktree-process-hygiene.md` §3). A `! command` typed from Remote Control (phone) arrives as plain text and does not run - never ask for one.

## Parity
Terse operator copy lives in the global `~/.claude/CLAUDE.md` (Working style); this file is the source-of-truth detail; memory lesson `feedback-session-handoff-and-context-hygiene` is the *why/how*. Composes with `coding-hygiene.md` (goal-driven) and `worktree-lifecycle.md` (per-task isolation).

**Working if:** sessions are cleared early and often without losing the thread; a fresh session resumes from `handoff.md` with zero re-explaining; no long degraded threads survive to the auto-compact wall.
