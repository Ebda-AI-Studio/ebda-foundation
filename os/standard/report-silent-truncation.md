# Report query with a hard row cap and no truncation signal

Pack: money, reliability | Probe type: S | Source: Ebda AI Studio audit 2026-10-26 BUG-9

## Claim
A reconciliation or report that silently stops at N rows reports a wrong total with full confidence.

## Scenario
Ebda's COD reconciliation silently truncated at 5,000 shipments and 20,000 remittance lines.

## Source candidate
- (medium) Hard take/limit of thousands of rows with no cursor, hasMore or truncation flag.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Paginate with a cursor to exhaustion, or fail loudly / return hasMore.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
