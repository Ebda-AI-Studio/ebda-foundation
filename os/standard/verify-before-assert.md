# verify-before-assert — check ground truth before calling anything a violation

Born from a single session (2026-07-20) in which the same failure fired **four times**: a rule was
read, pattern-matched, and asserted as fact without checking the thing it described. Three of those
became false accusations about Ahmad's own correct setup; one disabled tooling that three live
client sites depend on.

**The rule:** *an instruction describes the world; it is not evidence about the world.* Before
declaring something stale, unused, misplaced, cancelled, or in violation — **observe it**.

**Tradeoff:** costs 10–60 seconds per claim. Cheaper than one wrong purge.

## 1. The failure mode

A standing rule is a **compressed summary**, written at a moment in time, for a reason. Reading it
cold, the compression looks like a fact and the reason is invisible. So:

| The rule said | I asserted | Ground truth |
|---|---|---|
| "Vercel is CANCELLED — any Vercel rule you recall is obsolete" | disabled the Vercel plugin + purged the playbook | 3 client sites live on Vercel; `curl` → `server: Vercel` |
| "the org owns all project repos" | vault on a personal account = governance violation | the vault is deliberately personal — it holds `personal-and-life`, `key-decisions`, `people-and-clients` |
| same rule | "7 of 8 `_personal/` repos still on voidengineer-911" | **all 7** are on it — that IS the deliberate pattern |
| "no secrets in repos" | 5 public repos with tracked secret-shaped files | all `.env.example` placeholders; gitleaks clean |

Every one was checkable in under a minute. None were checked.

## 2. Must Always

- **Observe before asserting.** A claim that something is stale/unused/wrong requires evidence from
  the system itself, not from a document describing the system.
- **Prefer the runtime fact over the config claim.** Config on disk is an intention; the response
  header is the truth. `curl -sI <domain>` and read `server:` before believing any hosting doc.
- **Check the whole set before calling something an exception.** "7 of 8 are wrong" almost always
  means "8 of 8 are a pattern I don't recognise yet." Enumerate all N, then judge.
- **Read what the rule is FOR before applying it.** "Org owns all project repos" exists so client
  and platform code isn't trapped in a personal account. A personal knowledge vault is the case the
  rule is protecting, not violating.
- **Treat disabling/removing as a production action.** Tooling a live deploy path depends on is
  infrastructure, not clutter. Reversible ≠ safe to do unasked.
- **Verify your own report before delivering it.** `git push | grep … || echo ok` prints success on
  failure; `grep -c 'leaks found'` also matches "**no** leaks found"; an exit code from a chained
  command is the last command's, not the one that mattered. Confirm with an independent read
  (`git ls-remote`, a fresh `curl`, a re-query) — never the command's own optimistic output.

## 3. Must Never

- Never write a rule of the form *"any rule you recall about X is obsolete."* That phrasing
  suppresses the verification that would catch it, converting a fact into a standing order.
- Never write an unscoped deprecation. "Retired for the core platform; still live for the client
  menu tier" is the same length and cannot be over-applied.
- Never report a sweep clean without enumerating every scope — **including directories created
  earlier in the same session.** (2026-07-20: `~/.claude/workflows/` was missed while its own
  slash-commands were being authored, and the sweep was still reported clean.)
- Never let "the config says so" end an investigation when a one-command check is available.

## 4. The 60-second checks

| Claim about | Check |
|---|---|
| hosting / "migrated off X" | `curl -sI <domain>` → `server:` header; `ls .vercel/project.json wrangler.toml` |
| repo ownership / visibility | `gh api repos/<owner>/<name> --jq '.full_name, .private'` — for **every** repo, not a sample |
| "this deployed" | provider deployment **status**, not the event — `wrangler pages deployment list`; then `curl` the live change |
| "unused / safe to delete" | `grep -rl <name>` across CLAUDE.md + memory + scripts + settings before removing |
| "secrets exposed" | open the file — `.env.example` with placeholders is not a leak; `gitleaks detect` to confirm |
| "pushed" | `git ls-remote` / `git rev-parse origin/<branch>`, never the push command's own output |
| "gate is running" | confirm the binary exists (`ls node_modules/.bin/<tool>`) — a declared-but-uninstalled hook fails **open**, silently |

## 5. When you cannot verify

Say so, and say what would settle it. *"The docs say Vercel; I could not reach the domain to
confirm — run `curl -sI x.com` and check `server:`"* is a useful report. *"This is stale"* on the
same evidence is a false accusation with a confident voice.

**Composes with:** `coding-hygiene.md` §1 (don't assume, surface confusion),
`unified-audit.md` (triangulate sources), `audit-gating.md` (a finding needs evidence),
`deploy-verify.md` (verify the deploy, not the notification).
