# enumeration-integrity — a count is a measurement, and it fails silently

tags: [BOTH]
sources: `feedback-enumeration-is-a-measurement` — corpus-census session 2026-09-02

Born from one session (2026-09-02) in which the same corpus was counted three times and was wrong
every time — once too small by a 3,049-commit repo, once too large by 5,235 duplicated commits (a
third of the corpus), and once collapsed onto colliding ids. Each wrong number looked exactly like a
right one: no error, no warning, a plausible total. One of them was written straight into a plan.

**The rule:** *a number describing a set is a measurement, not a fact.* Every enumeration must be
reconciled against an independently derived total before it is written into a plan, a report, a
budget, or a decision.

**Tradeoff:** one reconciliation assertion per enumerator (about five lines) and a second count
derived a different way. It buys detection of omissions and duplications that produce no error at
all — the only failure class here that is invisible by construction.

## 1. The failure mode

| Enumerator | Reported | Truth | Mechanism |
|---|---|---|---|
| `for d in $(find … )` over a 34-repo census | 33 repos | 34 | a directory named `calude code meomry` **word-split on the spaces**; a 3,049-commit repo vanished with no error, and the total was then trusted and written into a plan |
| `existsSync(path.join(dir, ".git"))` | 41 repos | 34 | **7 git worktrees counted as separate repos**, duplicating 5,235 commits — a third of the corpus. A worktree's `.git` is a **file**; a canonical repo's is a **directory** |
| `path.basename(dir)` as the unit id | unique ids | collisions | `digital-card` existed at two paths; later `_scoped/<project>/project.md` collided on the id `memory:project` across **24** project directories |
| the namespacing fix, which assumed `_scoped/` was the only per-project directory | collisions resolved | still colliding | the tree held **seven** subdirectories, **five** of them per-project |
| a classifier returning the **first** matching layer over a whole document | 401 units in "money" | 53 | **77%** got there because the body mentioned a keyword once — a note about disk growth was filed as money because it contained the word "price". Scoring instead of first-matching moved **11 of 12** modules from THIN to ready |

The pattern across all five: the enumerator answered a question adjacent to the one asked
("has a `.git` entry", "shares a basename", "contains the word"), and nothing in the pipeline
compared its answer to the real question.

## 2. Must Always

- **Reconcile against an independent total, and fail on mismatch.** The loop's own counter vs
  `find … -print0 | tr -dc '\0' | wc -c`; the sum of per-bucket counts vs the input count; rows
  written vs rows read. A mismatch aborts — it does not warn.
- **Iterate paths NUL-safely.** `find … -print0 | while IFS= read -r -d '' p` or `mapfile -d ''`.
  Never `for x in $(find …)`, never an unquoted expansion. Assume every path contains a space, and
  may contain a quote or a newline.
- **Identify a unit by its full relative path, not a basename.** Where a short id is required it is
  `<namespace>:<relative-path>`, and the enumerator asserts `|unique ids| == |units|` before
  emitting anything. A namespacing fix that is not followed by that assertion has not been verified.
- **Discriminate the thing from its aliases.** A git worktree's `.git` is a file
  (`test -d "$d/.git"` distinguishes them); `git rev-parse --git-common-dir` resolves both to the
  canonical repo. De-duplicate by canonical identity, then assert no commit sha, row id, or file
  hash appears under two units.
- **Enumerate the container before assuming its shape.** List the actual subdirectories, table
  names, or bucket keys rather than hard-coding the one you happen to know about. Five of the seven
  directories here were per-project, and the fix that knew about one of them still collided.
- **Classify by score over the whole unit, never by first match.** Record, per unit, the winning
  score *and* the runner-up. A unit whose winner beats the runner-up by a single hit is
  `UNCLASSIFIED`, not classified — the honest bucket is a bucket.
- **Report the denominator and the mechanism with every count.** "401 in money" is ungradeable;
  "401 of 1,120, and 77% of them matched on one keyword in the body" is a finding that fixed itself.
- **Any number that reaches a plan, a report, a dashboard, or a customer carries the command that
  produced it**, verbatim, so a reader can re-run it. A number with no re-runnable provenance is a
  claim.

## 3. Must Never

- Never trust a count you did not reconcile — including one your own script produced minutes ago.
- Never let a skip be silent. An entry the loop cannot process raises; `continue` without a counter
  is how 3,049 commits disappear.
- Never fix a collision by adding a namespace without re-asserting uniqueness afterwards.
- Never carry a first-match classifier into anything graded, budgeted, routed, or shipped.
- Never present a total and a percentage derived from the same unreconciled pass as if they
  corroborate each other.

## 4. The reconciliation shape

```bash
# Canonical-repo census. A worktree's .git is a FILE; a canonical repo's is a DIRECTORY.
tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
found=0
while IFS= read -r -d '' gitent; do                      # NUL-safe: assume spaces in paths
  found=$((found + 1))
  repo=$(dirname "$gitent")
  # --git-common-dir resolves BOTH a repo and its worktrees to the one shared .git
  canon=$(cd "$repo" && cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P) \
    || { echo "FAIL: unreadable git entry: $repo" >&2; exit 1; }   # a skip is never silent
  printf '%s\n' "$canon" >> "$tmp"
done < <(find "$ROOT" -maxdepth 3 -name .git -print0)

total=$(find "$ROOT" -maxdepth 3 -name .git -print0 | tr -dc '\0' | wc -c | tr -d ' ')
[ "$found" -eq "$total" ] || { echo "census mismatch: saw $found of $total" >&2; exit 1; }
[ "$found" -gt 0 ]        || { echo "census examined NOTHING" >&2; exit 1; }

repos=$(sort -u "$tmp" | wc -l | tr -d ' ')              # de-dup on canonical identity
echo "$repos canonical repos from $found .git entries"   # always report the denominator
```

The last two lines are the whole lens: a mismatch aborts, and **zero is a failure, not a clean
result** (`gate-integrity.md` §2).

## 5. The 60-second checks

| Claim | Check |
|---|---|
| "N repos in the corpus" | re-count with a second method (`find -type d -name .git` vs `gh repo list`) and diff the name sets, not the totals |
| "these are N distinct repos" | `git rev-parse --git-common-dir` per entry; duplicates = worktrees |
| "ids are unique" | `sort ids \| uniq -d` must be empty — print it, do not assume it |
| "the loop covered every path" | run it against a directory whose name contains a space. Measured: two repos under `a b c/` and `plain/` → the NUL-safe census reports `2 canonical repos from 2 .git entries`; `for d in $(find …)` reports **4** |
| "the classifier is accurate" | sample 20 units in the largest bucket and read why each landed there |
| "nothing was skipped" | compare the emitted count to the input count, in the script, as an assertion |

## 6. Grading

- `0` — counts produced with no reconciliation, unquoted `for x in $(…)` iteration, basename ids, or
  a first-match classifier feeding a decision.
- `1` — reconciliation present but warning-only; or ids namespaced without a uniqueness assertion;
  or counts reported without denominators.
- `2` — every enumerator reconciles against an independent total and aborts on mismatch, iterates
  NUL-safely, asserts id uniqueness, de-duplicates on canonical identity, scores rather than
  first-matches, and every published number carries its command.

**Composes with:** `gate-integrity.md` (an empty input set is not a pass),
`verify-before-assert.md` (enumerate the whole set before naming an exception),
`unified-audit.md` (a fleet count is an enumeration), `observability.md` (a metric is a count).
