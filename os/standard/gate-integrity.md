# gate-integrity — a gate that cannot fail reports success

tags: [BOTH]
sources: `feedback-gate-that-cannot-fail-reports-success`, `feedback-head-to-head-always-use-the-better-tool` (visible-skip checklists) — corpus-pipeline session 2026-09-02; gitleaks 8.30.1 measured on macOS 15

Born from one session (2026-09-02) in which a corpus pipeline's **secret gate reported 0 findings on
every input it had ever been given** — and would have reported 0 findings on a corpus full of live
keys. Three separate fail-open holes lived in the same 40-line gate: one in how the report was
written, one in how a zero exit code was read, and one in what happened when the input directory was
empty. Nothing was red. Nothing had ever been red.

**The rule:** *a gate's PASS is evidence only if that same gate, unchanged, can be made to fail.*
Bind the verdict to an artifact the check actually produced — never to the tool's own self-report.

**Tradeoff:** a receipt file, a downstream refusal path, and one recorded negative control per gate —
roughly 20 lines and one extra failure mode you have to explain to whoever hits it. It buys a gate
that goes red on plumbing breakage instead of quietly passing forever.

## 1. The failure mode

A gate has two jobs — *examine the thing* and *report a verdict*. When the plumbing between them
breaks, the verdict survives and the examination does not. The verdict then looks exactly like a
pass.

| What was believed | What was true |
|---|---|
| `gitleaks detect --no-git --source <dir> --report-path /dev/stdout` prints the JSON report to stdout | on **gitleaks 8.30.1** `/dev/stdout` receives **nothing**; stdout carries only the human-readable log |
| the parser read the report and found 0 findings | the parser read an empty string, fell back to `[]`, and reported 0 — it would have returned 0 for **any** corpus |
| `detect` is the current scan subcommand | `detect` is deprecated and absent from `gitleaks --help` on 8.30.1 |
| exit code 0 means the scan was clean | after the first fix, an **unreadable report + exit 0** still returned "clean" — an exit code is the tool's self-report, not an observation |
| the stage examined the corpus | run against an empty input directory, the same stage reported success having examined **0 files** |

The second hole is the instructive one: it was **symmetric with the first and survived the first
fix**, because the fix addressed the path that had been observed rather than the class. A gate has
more than one exit path, and every exit path that can reach "pass" is a candidate fail-open.

## 2. Must Always

- **Every gate has a recorded negative control.** An input that makes it fail, exercised at least
  once, with the red result recorded (date, mutation, message). A gate with no recorded failing
  input grades **0**, regardless of how green it is.
- **Bind the verdict to an artifact, not to a process.** The receipt protocol:
  1. delete any existing receipt *before* touching the input,
  2. run the check,
  3. write the receipt **only** on a pass, recording the count of units examined,
  4. the downstream stage refuses to run without a receipt whose count matches its own input count.
  A stale receipt then cannot be mistaken for a fresh pass, and a skipped stage cannot be mistaken
  for a clean one.
- **An empty input set is a FAIL or an explicit, logged SKIP — never a pass.** "0 files scanned, 0
  findings" is a plumbing report, not a security result. Assert `units_examined > 0`.
- **An absent, zero-byte or unparseable report is a FAIL**, whatever the exit code says. `stat`/`wc -c`
  the report before parsing it.
- **Never write a machine-readable report to `/dev/stdout`, `/dev/stderr`, or a pipe** when the tool
  offers `--report-path`. Write to a real file in a temp dir and read it back. Several scanners
  (gitleaks among them) treat the report sink and the log sink as different streams.
- **Parser fallbacks fail the gate, they do not empty it.** `JSON.parse(x) ?? []`,
  `catch { return [] }` and `|| echo '[]'` all convert a broken gate into a passing one. On a parse
  error: throw.
- **Pin the gate's tool version and re-check its subcommand.** `<tool> --version` recorded in CI, and
  `<tool> --help | grep -w <subcommand>` in the gate's own self-test. A deprecated subcommand is one
  release away from `exit 0` with no output.
- **Fix the whole class in one pass.** When one fail-open is found, audit *every* other route to
  "pass" in the same gate before shipping — here the second hole was found only because the class
  was swept after the first fix.
- **Name the layer that actually holds the line, and gate THAT.** A build gate advertised as proof
  that no paid content reaches a browser proved it only for the *static* build — a server-side
  render never appears in build output at all, so the layer carrying the guarantee was a lint rule
  and a boundary test, not the gate named after it. Ask of every gate: what input shape would the
  regression take, and does this gate's evidence source contain that shape? Fix by **adding an arm**,
  never by narrowing the advertised claim to match what it happens to check.
- **The positive control needs its own verification.** A control is a file, and a file can be inert.
  One build's suggested control pointed at a 2 KB loader shim that never contained the sentinel — the
  control passed by not existing. Verify by **inversion**: a deliberately bogus canary must make the
  gate REFUSE to report clean, and removing the controls must make that same bogus run exit 0. If
  both do not hold, the control is decoration.
- **A checklist an agent runs is a gate too, so its skips must be visible.** "Run through all 15
  silently" cannot fail: a skipped rule and a passed rule look the same. Copy the applicable items
  into the todo list. Each one ends as done (with evidence) or `skip: <reason>`, and silence counts
  as a fail. Label every claim in the closing report **measured**, **inferred** or **guess**.
  (Lifted from cursor/plugins pstack playbook discipline, 2026-10-08.)
- **Apply the same discipline to runtime authorization gates** — see §3.

## 3. Runtime gates: never branch on an injected value's declared shape

A gate read `entitled ? allow : deny`, where `entitled` came from an **injected** function typed
`() => Promise<boolean>`. TypeScript erases at runtime, so the type was a comment. Every one of
`{}`, `1`, `"yes"` and — worst — the string `"false"` is truthy, and each of them granted access to a
paid product. `"false"` is the dangerous case precisely because it *reads* as a denial: it is what a
boolean looks like after a round trip through an env var, an HTTP header, a JSON column, or a form
field.

- **Compare to a literal at every trust boundary**: `=== true`, never a bare truthiness check, for
  entitlement, ownership, admin, verified, consent, and feature-flag results.
- **Parse and narrow every injected seam's return before branching on it.** A DI boundary is an
  edge; edges get validation (Zod or an explicit `typeof v === "boolean"` guard), exactly like a
  request body does.
- **Harden every seam in the module, not the one you were shown.** When the first seam here was
  fixed, the *other* injected seam in the same module was still branching on an unparsed return.
- **Check:** grep for ternaries and `if (await …)` on values that cross a DI boundary. Each must
  compare against a literal or come out of a parser.

## 4. Must Never

- Never accept a process exit code as evidence about the world the process inspected.
- Never let "clean" be reachable through a code path that never read the artifact.
- Never ship a gate whose only proof of life is that it is green.
- Never treat "the gate is configured" as "the gate runs" — a declared-but-uninstalled binary fails
  open, silently (`verify-before-assert.md` §4).

## 5. The 60-second checks

| Claim | Check |
|---|---|
| "the secret gate is running" | plant a synthetic test credential in the scanned tree, re-run — the gate must go red; remove it and confirm green |
| "the report parsed" | `wc -c <report>` before parsing; `0` = FAIL |
| "`--report-path /dev/stdout` works" | run it, redirect stdout to a file, and look for JSON. If the JSON is missing, the report never existed |
| "the stage ran" | assert `units_examined`, and compare it to an independently counted input total (`enumeration-integrity.md`) |
| "the subcommand is current" | `<tool> --help \| grep -w <subcommand>` in the gate's self-test |
| "the downstream stage was protected" | delete the receipt and re-run — the downstream stage must refuse, not proceed |
| "entitlement is a boolean" | `typeof v === "boolean"` at the seam; grep for `=== true` at each branch |

## 6. Grading

- `0` — a gate exists with no recorded negative control, or any route to "pass" that does not read
  the artifact (parser fallback, exit-code trust, empty-input pass).
- `1` — negative control recorded, but the verdict is still bound to the process (exit code) rather
  than to a counted artifact, or a downstream stage will run without a receipt.
- `2` — receipt-bound verdict with a unit count, empty input fails, parse failure fails, negative
  control recorded and dated, and every trust-boundary branch compares to a literal.

**Composes with:** `verify-before-assert.md` (an exit code is a claim, not evidence),
`mutation-proof.md` (the negative control is the mutation), `security.md` (secret scanning,
0/0/0/0), `testing.md`, `audit-gating.md` (a finding needs evidence — so does a clean bill).
