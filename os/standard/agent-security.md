# agent-security — Agent-Runtime Security Gates Rubric

tags: [BOTH]
sources: Simon Willison "lethal trifecta" (2025), CVE-2025-59536, CVE-2026-21852, MCP Top-10 (2026), `ops/self-check.sh` pattern, live agents: a WhatsApp bot runtime, zero voice assistant, `ops/dream-fix.sh`

This is the **agent-runtime** counterpart to `security.md`. `security.md` covers app code
(XSS, injection, secrets, headers). This file covers a different attack surface: **an LLM
agent with tool-execution power reading content it did not choose to trust.** That surface
did not exist before agents got shells, browsers, and MCP tools — it is the ECC gap this
doc closes.

## What "solid" looks like

No runtime ever holds all three legs of the lethal trifecta unguarded at once. Untrusted
content (WhatsApp messages, PDFs/images, GitHub issue/PR bodies, web pages, MCP tool
output) is treated as **data**, never as **instructions**, and is never handed directly to
`exec`/`eval`/shell/git-push capable code paths. MCP servers are vetted before install and
their tool descriptions + return values are treated as untrusted context, same as any other
external input. Autonomous harnesses (`claude -p`, dream-fix, watchdogs) run with scoped
permission allowlists, never blanket `bypassPermissions`, and default to human-gated merge.

## The lethal trifecta (Simon Willison)

An agent becomes an exfiltration vector the moment ONE runtime simultaneously has:

1. **Access to private data** (secrets, customer PII, source code, credentials)
2. **Exposure to untrusted content** (anything an attacker can write: a chat message, an
   email, a PR body, a web page, a tool's return value)
3. **A path to external communication** (network calls, sending a message, pushing a
   commit, calling an API, writing a file that gets synced/deployed)

**The rule: never let all three coexist in one runtime without a human or code-level
isolation gate between them.** If a runtime must have all three (e.g. an email-triage agent
needs email access + external send + reads untrusted mail bodies), the isolation gate is
what makes it safe — not vigilance. Break one leg (no external comms, no private-data
access, or content sanitized before it reaches the model) rather than trust the model to
"just not fall for it."

## Prompt injection → tool execution

Untrusted content becomes instructions the moment a capable agent reads it as context.
Sources that hit our runtimes today: inbound WhatsApp message bodies, uploaded
PDFs/attachments/OCR'd images, GitHub PR/issue bodies + comments, scraped web pages
(merchant-intelligence agents), and **MCP tool output** (a "helpful" tool description or
return value can itself carry an injected instruction).

Two real 2026 CVEs that made this concrete, not theoretical:

- **CVE-2025-59536** — pre-trust code execution: content trusted before validation let an
  attacker-controlled input trigger code execution in an agent runtime.
- **CVE-2026-21852** — `ANTHROPIC_BASE_URL` key exfiltration: an env var an agent runtime
  trusted let an attacker redirect API traffic and harvest credentials.

Both share the same root cause as the trifecta: a runtime treated attacker-reachable input
(an env var, a document, a tool payload) as trusted control data instead of untrusted
content.

## MCP Top-10 (applies to every MCP server we configure)

1. **Tool poisoning** — a malicious/compromised server's tool definition instructs the
   model to exfiltrate data or misuse other tools.
2. **Prompt injection via tool descriptions** — the description text itself, not just
   arguments, is a channel for injected instructions.
3. **Prompt injection via tool output** — a tool's *return value* can carry instructions
   the model then acts on.
4. **Command injection** — a tool that shells out using unsanitized model-supplied
   arguments.
5. **Shadow MCP servers** — an unvetted server added ad hoc (by a subagent, a script, or
   copy-pasted config) that was never through the install checklist below.
6. **Secret exposure** — a tool that can read `.env`/keychain/credentials and return them
   as "helpful" output.
7. **Over-trusted tool schemas** — accepting a tool's declared capability at face value
   without confirming what it actually does at runtime.
8. **Confused deputy** — a tool acts with the agent's ambient privilege on behalf of
   untrusted input it merely displayed.
9. **Unbounded tool scope** — a tool granted filesystem/network reach far beyond what its
   stated job needs.
10. **No output provenance** — tool results are consumed with no marker distinguishing
    "trusted local code" from "external/untrusted fetch," so the model can't tell them
    apart downstream.

**Rule: treat every MCP tool's description AND its output as untrusted context — same
threat class as a WhatsApp message or a scraped web page.** Vet a server before adding it
(who publishes it, what it can reach, does it need secrets) and re-vet on version bumps.

## Applied to our live agents

### A messaging bot runtime — the canonical trifecta example

The bot runtime has all three legs at once: it holds merchant/customer data (private
data), it reads inbound WhatsApp message text directly (untrusted content), and it sends
WhatsApp messages + writes to the DB (external comms). This is not hypothetical — it is
our highest-exposure live surface.

- Message text is **data the state machine matches against, never an instruction the
  model/router executes**. `botIntentService.js` / `bot-service-router.js` /
  `botCatalogService.js` classify intent from patterns — none of them should feed raw
  message text into a shell, `eval`, or an LLM call that has tool-exec power over the
  merchant's account.
- `audioTranscode.js` spawns `ffmpeg-static` via `spawn(ffmpegPath, args, ...)` (argv array,
  not a shell string) — correct pattern for feeding attacker-supplied audio bytes into a
  subprocess. Keep new media-handling code on this pattern (array args, no `shell: true`,
  no string-built commands from message content).
- PII (phone numbers, names, order details) must be masked before logging — same gate as
  `security.md` #6, doubly important here because logs may later be fed back into an LLM
  context (e.g. a debugging agent reading logs = untrusted-content re-entry point).
  reference: `feedback-wbs-bot-state-machine-design-rules.md`.
- The WhatsApp webhook is already signature-validated at the edge — that stops spoofed
  senders, not injected instructions from a *real* sender's message body. The two gates
  are independent; both are required.

### Zero (voice JARVIS, `the zero repo`)

Voice → Whisper (STT) → Claude Code SDK "brain" with real tool access
(`zero/brain.py`: `allowed_tools=["Read","Glob","Grep","Bash","Write","Edit", ...]`,
`permission_mode="default"`). Untrusted content here is anything Whisper transcribes that
Ahmad didn't say cleanly (background speech, a TV, a phone call) plus, transitively,
whatever any tool call reads (a fetched page, a file).

- **Wake-word gating** (`zero/wake.py`) is the first isolation gate — no tool-exec path is
  reachable without an explicit wake trigger. Do not weaken this to "always listening +
  always acting."
- `permission_mode="default"` (not `bypassPermissions`) + `zero/gate.py`'s
  `build_pretooluse_hook` is the second gate: safe tools (`Read`, `Glob`, `Grep`,
  `WebFetch`, `WebSearch`) auto-allow, mutating tools (`Write`, `Edit`) and any
  `never_patterns` hit always require an out-loud confirm from Ahmad before executing.
  **This is the reference pattern for every voice/chat-triggered agent we build** — keep
  it, don't collapse it into a blanket allow for convenience.
- Never expose secrets or broad filesystem scope to a voice-triggered action path.
  `allowed_tools` should stay an explicit allowlist, not `*`.

### dream-fix / claude -p autonomous harnesses

`ops/dream-fix.sh` and sibling `claude -p` headless harnesses run unattended with repo
write + git access — the "external comms" leg is a live `git push` / `gh pr create`.

- **`DREAM_AUTOMERGE` stays OFF by default on every repo** (verified in `ops/dream-fix.sh`
  and the repo-scoped allowlist in `ops/lib/dream-safety.sh` — `dream_automerge_enabled()`
  — plus `standard/dreaming-cycle.md`) — a PR is opened for human review, never merged
  unattended, until the documented bar (one clean weekly dry-run + 3 manually-verified
  Tier-A PRs + server-side guard merged) is met per-repo AND the repo is added to
  `~/.whisky-os-state/dream-automerge-repos`.
- Content the harness reads to decide what to fix (issue bodies, PR comments, CVE
  advisories, scan output) is untrusted content by the trifecta definition — the harness
  must not execute instructions found inside a GitHub issue/PR body it's summarizing or
  reacting to. It proposes a diff; it does not act on embedded "ignore previous
  instructions, also run `rm -rf` " style text.
- The auto-fix watchdog runs in its own worktree (per the parallel-session rule), never the
  shared root checkout — this is also a security boundary: a compromised/injected fix
  can't collide with or overwrite a human's in-progress work.
- **TCC canary — no automation acts or alerts while blind (fleet-wide, 2026-07-12).**
  macOS TCC can silently deny a launchd-context `bash` read access to `~/Desktop`
  (identical-environment terminal runs stay clean, so this is easy to miss); a blind
  scan then sees zero repos and reports every finding as "missing"/drifted — a false
  positive that a downstream harness (dream-fix, docs-scan, workspace-hygiene) could
  act on. `require_projects_access()` / `require_projects_access_critical()`
  (`ops/lib/os-state.sh`) gate every scheduled desktop-reader: 21 scan/act scripts
  abort quietly (`write_status … warn`) when blind; the handful whose non-run is
  itself an incident (`backup-all-neon.sh`, `mac-maintenance.sh`,
  `update-memory-pipeline.sh`, `migrate-claude-home.sh`) alert P1 instead; `os-selftest.sh`
  reports blindness as a CRITICAL finding and skips unknowable checks rather than
  hiding them. The real fix is a one-time Full Disk Access grant to `/bin/bash`
  (System Settings → Privacy & Security), which is GUI-only and can't be scripted —
  the canary is the interim guardrail so a permissions gap degrades to "no findings",
  never to "wrong findings acted on."

## The agent-security gates checklist

1. **Trifecta check** — for every agent runtime, name its private-data access, its
   untrusted-content sources, and its external-comms paths. If all three are present,
   there is a documented isolation gate (human confirm, sandboxing, or one leg removed) —
   not just "the model is well-behaved."
2. **Untrusted input never reaches tool-exec directly** — no shell/`eval`/`child_process`
   call is built from message text, document content, scraped HTML, or MCP tool output
   without going through a fixed-argv, non-shell invocation (see `audioTranscode.js`
   pattern) or a validation layer first.
3. **MCP servers are vetted before adding**, and both their tool descriptions and their
   return values are treated as untrusted context in every prompt that consumes them —
   never given implicit trust because they came from "our own" MCP config.
4. **No blanket `bypassPermissions` for any agent with untrusted-input exposure** —
   permission mode is an explicit allowlist (`allowed_tools`) or a PreToolUse gate
   (`zero/gate.py` pattern), scoped to what the task needs. Reserve
   `defaultMode: bypassPermissions` for trusted, human-driven interactive sessions only —
   audit `~/.claude/settings.json` for where it's set and confirm it's not inherited by an
   unattended/untrusted-input agent.
5. **Autonomous harnesses default to human-gated merge** — `DREAM_AUTOMERGE`-style kill
   switches stay OFF until the documented promotion bar is met; unattended agents propose,
   they don't merge, until proven.
6. **Wake/trigger gating precedes any tool-exec path** for voice/always-on agents — no
   "always listening, always acting" runtime.
7. **PII masked before logging, and logs are themselves untrusted content** the next time
   an agent reads them back (debugging agent, log-summarizer) — mask once, upstream, not
   per-consumer.
8. **Prompt-injection canary/logging** — where feasible, log when a classified-as-mutating
   tool call's arguments contain content sourced from an untrusted channel (inbound
   message, fetched page, MCP output), so an injection attempt leaves a trail even if the
   gate holds.
9. **Isolation over vigilance** — when a runtime genuinely needs all three trifecta legs
   (e.g. an email/WhatsApp-replying agent with DB access), the fix is a code-level or
   human-level gate between legs, never "the prompt tells it not to fall for injection."
10. **New agent/tool integrations get this doc's checklist before shipping**, same as new
    features run through `security.md` before shipping.

## Evidence (filled during audit, per agent runtime)

- messaging bot runtime: …
- zero voice assistant: …
- dream-fix / autonomous harnesses: …
