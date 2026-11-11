# Lens Calibration — a new audit lens is not done until it has been wrong on a real repo

sources: reference-php-laravel-lens-pack, feedback-gate-that-cannot-fail-reports-success,
feedback-a-filter-that-reads-the-path-not-the-content, feedback-test-that-passes-for-the-wrong-reason

**The failure this grades is not a lens that misses. It is a lens that fires 110
times on one repository and is right zero times** — which costs the same as
finding nothing, plus the reader's trust. Measured 2026-09-23 while adding 11
PHP/Laravel lenses to `mypovonai-audit`: an earlier route-authorization attempt
produced 110 findings on a single Laravel repo, none of them real, because it
tracked middleware groups by brace depth and Laravel declares them five ways.

## Grade 2

Every lens ships **five** artifacts, and has been run against a real repository
with independent ground truth:

1. a probe that always exits 0 and says `skipped <lens> <precise reason>` when it
   cannot apply — never a silent pass;
2. a lens manifest with one criterion per finding site;
3. a rubric entry grading 2 / 1 / 0;
4. a **known-bad fixture** that proves it can fire;
5. a **clean twin** — the same construct written correctly — that proves it can
   stay quiet.

Plus: a per-finding `REAL` / `FALSE POSITIVE` verdict recorded against a real
repo, and a mutation proof (break the rule, name the gate that reddens, restore
byte-identical).

## Grade 1

Fixture and probe exist; the lens has never met a real repository, or it met one
and the finding count was accepted without a per-finding verdict.

## Grade 0

No clean twin. A lens with only a known-bad fixture is proven able to fire and
**unproven able to stay silent**, which is the expensive half.

## The rules this encodes

### Severity follows REACHABILITY, not code shape

The same defect is a different finding depending on who can reach it. An
unscoped `Model::find($id)` inside an admin-gated controller is a code-boundary
defect (**high**): loading any record by id is the admin's job. The same call
reachable from a route with no middleware is the exploit (**critical**). On the
calibration repo that split 49 findings into 41 high and 8 critical — and the 8
are the ones the ground-truth report named. Marking all 49 critical buries them.

### A finding another lens already owns is noise here

A shared-password session gate is a secrets finding. An authorization lens that
re-reports it as "missing middleware" has not found a second defect; it has
printed the first one twice. Declared middleware counts as coverage **however
weak its own check is** — and the rubric says so, in writing, at the lens.

### Zero is a claim that needs a measurement

A lens reporting 0 on a repo is indistinguishable from a lens that is dead until
you force it. Invert the predicate that suppresses findings and count what comes
out: if the answer is still 0, the lens is blind. The PHP authz lens returns 0
legitimately — forcing its coverage test to fail flags 128 routes.

### A lens is only as alive as its stack detector

`is_php` excluded `vendor/` but not `node_modules/`, so ONE stray `.php` file
inside a single npm dependency made a Next.js repository answer "yes, this is
PHP". Detect a stack by evidence, exclude every dependency directory, and assert
the detector on a repo of the WRONG stack — not just the right one.

### The gate needs its own negative control

A no-leak gate read each fixture's forbidden literals from a list *inside that
fixture*, then confirmed each literal still existed by grepping the fixture
directory — which contains the list. Every entry vouched for itself, and a
literal present in no source file passed. A control must exclude the artifact
that declares it, and must be proven by declaring something false.

### A probe is only proven from the directory it ships in

The declarative `rule_*` probe helpers split their glob list with an unquoted `for g in $1`, so the shell expanded `*.md` against the *current directory*. Run from a scratch directory the probes passed; run from the package directory (which holds README.md) a clean twin matched no files. Pass patterns as data (`set -f` or an array), run the per-lens check from the real package directory, and let the full fixture gates (fires, clean twin, site coverage) be the only proof. On a loaded host the legacy pathname preflight (2 s deadline) can also report `coverage incomplete` with zero findings: re-run before blaming the probe, and never read that skip as clean. sources: feedback-probe-globs-expand-against-cwd

## Applies to

Any probe/lens fleet: `mypovonai-learn/fleet`, `ops/` watchdog checks, and any
`standard/` lens that ships as a probe (see `an-os-lens-must-ship-in-the-product`).
