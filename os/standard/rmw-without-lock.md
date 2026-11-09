# Read-then-overwrite on shared state with no lock or atomic update

Pack: money, reliability | Probe type: S | Source: Ebda AI Studio audit 2026-10-26 BUG-2, BUG-5

## Claim
Reading a row and writing back an absolute value computed in application code loses concurrent updates; use an atomic increment, a lock or a version column.

## Scenario
Ebda PO receive: a double-click doubled stock, and the product-stock write was an absolute overwrite that lost a concurrent sale. InstaPay refund recording appended to an array read earlier, so a double-submit over-refunded.

## Source candidate
- (high) findUnique/findFirst followed by update() with no transaction, row lock, atomic increment or version check in the file.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
UPDATE ... SET x = x + n (or increment:), or SELECT ... FOR UPDATE inside a transaction, or a version column checked in WHERE.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
