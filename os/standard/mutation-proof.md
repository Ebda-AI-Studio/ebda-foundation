# mutation-proof — a defence needs a test you can make fail

tags: [BOTH]
sources: `feedback-test-that-passes-for-the-wrong-reason` — session 2026-09-02, four false-green defences in one sitting

Born from one session (2026-09-02) in which **four** separate defences were reported as proven by
passing tests, and all four were proven by something else. The worst: seven new security tests were
written for a hardened session check, and they passed against the **unfixed** code — the cookie had
been renamed in the same round, so every case returned 401 because no cookie was found at all, not
because the defence worked. Typecheck, lint and CI were green throughout.

**The rule:** *green is the null result.* A test proves a defence only after you have broken that
defence, watched **that named test** go red, and restored the file byte-identically.

**Tradeoff:** 2–5 minutes per defence, plus the discipline of restoring from git and proving it with
a checksum. It caught four false-green defences in one session that no other gate could see.

## 1. The failure mode

A test asserts an *outcome*. A defence is one of several reasons that outcome might occur. When the
test passes, it tells you the outcome held — not which reason produced it. Every failure below is
that gap.

| The test appeared to prove | What actually made it pass |
|---|---|
| 7 new tests prove the hardened session check rejects forged sessions | the cookie was **renamed in the same round as the fix**; every case returned 401 because no cookie was found at all. The tests passed against unfixed code |
| `expect(cookie).toContain("Path=/")` proves the cookie is host-scoped | `Path=/course` satisfies `toContain("Path=/")` — and breaks the `__Host-` prefix, which would kill login outright in production |
| regenerated gitleaks suppressions match the current scan | the scan they were generated from was **itself suppressed** by the old ignore file; one fingerprint was silently dropped from the new baseline |
| the new row-level revocation check is covered | it duplicated the SQL clause it was added beside, making that clause **invisible to every test** — adding a defence hid another one |

Two of these are worse than an untested defence, because an untested defence does not carry a green
check next to it.

## 2. Must Always

- **Mutation-verify every defence before claiming it.** The four steps, in order:
  1. **Break exactly that defence** — one line, one clause, one guard. Not the module.
  2. **Confirm the specific test fails, by name.** `<file> › <test name> — FAILED` in the record. "The
     suite went red" proves nothing about which test binds to which defence.
  3. **Restore from git**, never by retyping, and prove it: `shasum -a 256 <file>` before and after
     must match.
  4. **Record the table** (§4) in the PR body.
- **A test you cannot make fail is deleted or fixed** — it is not kept "for coverage". Coverage that
  cannot fail is a false green with a percentage attached.
- **Assert the whole value, not a prefix or a substring.** `toBe("/")` not `toContain("Path=/")`;
  anchored regexes (`/^__Host-/`) not bare `includes`; exact strings for cookie attributes, security
  headers, CSP directives and redirect targets. A substring assertion is satisfied by the superstring
  that breaks you.
- **When a fix and a rename land together, mutation-verify against the PRE-fix code.** Check out the
  parent commit's version of the file under test, run the new tests, and require them to fail. A test
  that also passes on unfixed code has measured nothing.
- **Regenerate a baseline only with the old baseline removed.** Suppression files, gitleaks
  `.gitleaksignore`, snapshot files and lint baselines are self-referential: a scan run under the old
  baseline cannot see what the old baseline hides. Delete it, rescan, then **diff the fingerprint
  sets and account for every entry that disappeared**.
- **Test each layer of a belt-and-braces defence independently.** Two layers enforcing one invariant
  means neither is tested — disabling either leaves the suite green. Each layer needs a test that
  fails when only that layer is removed.
- **The mutation matrix is a claim, not a record.** A reviewer **re-runs** the matrix; it never reads
  it. On one build a row recorded CAUGHT for removing an error-scrubbing guard; re-measured, the
  suite was 296/296 **green** — the implementation was right, the test guarding it could never fail,
  and the matrix said otherwise, which is the part that stops anyone looking again. A matrix taken on
  trust is a false green with a table attached.
- **Correct a false row IN PLACE.** Strike it through in the original matrix, mark it
  `FALSE — SUPERSEDED`, and name the measurement that overturned it. A correction filed only in a
  later document reproduces the original defect in miniature: the record still says proven, and the
  record is what the next reader consults.
- **A substring match is not a scope — when targeting a mutation, not only when asserting.** Four
  instances in one build: a mutation applied to an identical-looking `return null` in the *wrong
  function* and was nearly logged as a survivor; a sink assertion matched a different module's code;
  a URL test passed because the preview path is a superstring of the sales path. Before recording a
  survivor, confirm the edit landed in the function under test (`git diff` the hunk, not the file).
- **Verify the measuring instrument before believing a survivor.** A mutation driver read a stale
  `--outputFile` and reported a hung suite as SURVIVED. Separately, mutations were "caught" by a
  runtime **arity** error rather than by the security property, and had to be redone
  arity-preserving. A survivor and a broken harness look identical from the report.
- **Adding a layer hides the layer beneath it — re-prove the old one in the same commit.** A new
  row-level revocation check made the SQL clause beside it invisible to every test, so the clause
  became free to delete silently. The inverse also occurred: two guards masked each other so neither
  was ever proved, and the correct fix was to *delete one*. A guard whose loss nothing can detect is
  not defence in depth.
- **When a new check duplicates an existing one, say so in the diff** and keep the isolating test for
  the old one, or the old clause becomes dead weight nobody dares delete and nobody can prove works.

## 3. Must Never

- Never report "N tests added, all passing" as evidence a vulnerability is closed. Say which mutation
  made which test fail.
- Never restore a mutated file by retyping it from memory — restore from git and checksum it.
- Never accept a broad break (deleting the module, breaking a shared import) as the mutation. It
  turns everything red and isolates nothing.
- Never mutation-verify on a branch you then force-push over without confirming the working tree is
  clean; a left-behind mutation is a shipped vulnerability.

## 4. The record it produces

A PR touching any defence carries this table. It is what an audit run grades.

| Defence | File:line | Mutation applied | Test that went red | Restored (sha256 match) |
|---|---|---|---|---|
| host-scoped session cookie | `session.ts:41` | dropped the `__Host-` prefix | `session.test.ts › rejects non-host-scoped cookie` | ✅ |
| row-level revocation | `entitlement.ts:88` | removed the `revoked_at IS NULL` predicate | `entitlement.test.ts › denies a revoked row` | ✅ |

An empty cell in the fourth column is a finding. An empty cell in the fifth is an incident.

## 5. Where this is mandatory

Non-negotiable for: authn/session, entitlement and paywall gates, RLS / tenant isolation, money
paths, secret and dependency gates, consent, erasure and export endpoints. Elsewhere it is
recommended, not graded.

## 6. Grading

- `0` — new defences shipped with passing tests and no mutation record; or substring/prefix
  assertions on security-relevant values.
- `1` — mutation performed but not recorded, or recorded at suite level ("tests went red") rather
  than per named test; or a regenerated baseline with no fingerprint diff.
- `2` — the §4 table present per defence, per-named-test red confirmed, byte-identical restore
  proven by checksum, each layer of a duplicated defence isolated.

**Composes with:** `gate-integrity.md` (a gate's negative control is a mutation),
`testing.md` (the five layers), `verify-before-assert.md` (verify your own report),
`security.md`, `auth.md`, `rls.md`.
