# coding-hygiene — universal LLM-coding-pitfall guardrails (Karpathy)

Andrej Karpathy's 4 behavioural guardrails against the common LLM-coding failure modes. MIT, from `multica-ai/andrej-karpathy-skills` (skill `karpathy-guidelines`), folded into the global operator CLAUDE.md so it applies to EVERY task. They complement the code-quality non-negotiables; the genuinely-new adds over the rest of `standard/` are **Simplicity** and **Surgical changes**.

**Tradeoff:** biases caution over speed — use judgment on trivial tasks.

## 1. Think before coding
Don't assume, don't hide confusion, surface tradeoffs. State assumptions explicitly; if multiple interpretations exist, present them (don't pick silently); if a simpler approach exists, say so and push back; if something's unclear, STOP and ask. (Pairs with plan-before-code + AskUserQuestion.)

## 2. Simplicity first
Minimum code that solves the problem, nothing speculative: no unasked features, no single-use abstractions, no unrequested "flexibility"/configurability, no error handling for impossible scenarios. If 200 lines could be 50, rewrite. Test: *"would a senior engineer call this overcomplicated?"*

## 3. Surgical changes
Touch only what the request needs; don't "improve" adjacent code/comments/formatting; match existing style even if you'd do it differently; remove only the orphans YOUR change created; mention (never silently delete) pre-existing dead code. **Every changed line traces to the request.** (Composes with `worktree-lifecycle.md` + the blast-radius sweep — surgical scope, then sweep the refs you DID change.)

## 4. Goal-driven execution
Turn tasks into verifiable goals ("fix the bug" → "write a failing test that reproduces it, then make it pass"); state a brief plan with a verify-check per step; loop until verified. (Composes with `testing.md` + `audit-gating.md`.)

**Working if:** fewer unnecessary diff lines, fewer rewrites from overcomplication, clarifying questions come BEFORE implementation not after mistakes.
