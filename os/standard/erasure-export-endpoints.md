---
sources: mypovonai-software-layer-erasure-export-endpoints, privacy-placeholders-and-erasure-ordering
upstream: voidengineer-911/mypovonai-learn
---

# Erasure and export route coverage

## Source candidate
Prisma projects storing email/phone require discoverable erasure and data-export route declarations.

The probe is a bounded lexical source check. It reports candidates with file/line evidence and deliberately does not claim that local guard names prove the guard is effective. A judge must inspect reachability, middleware, imports and framework semantics before grading. Runtime configuration and database state are not inferred.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.

## Erasure ordering and placeholder identities (2026-10-25, Ebda consent/erasure work)
**Proof before scrub.** An erasure step read data that an earlier step had already scrubbed - the proof/receipt was computed
AFTER order anonymisation, so it proved nothing and the erasure failed open. Rules: (1) compute every proof (hashes, row
counts, ids, the recipient list) BEFORE the first scrub; (2) the proof step fails CLOSED on empty/unexpected input; (3) one
end-to-end test erases a seeded customer with real rows in every dependent table and asserts the receipt content and
that nothing identifying remains - per-step mocks cannot see an ordering bug.

**Placeholders never use a real domain.** Placeholder/anonymised emails (e.g. `forcestore.kw`, a real third-party domain)
send mail to strangers. Use RFC 2606 reserved names: `.invalid` (or `example.invalid`). Every outbound send path drops
`*.invalid`, and a test scans fixtures/seeds/anonymisation constants for any email domain outside an allowlist.
Grading: High if an erasure receipt can be computed from already-scrubbed data; High if a placeholder domain can resolve.
