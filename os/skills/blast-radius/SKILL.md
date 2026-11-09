---
name: blast-radius
description: Use before claiming a change done, and for "what could this break". Sweeps every touched identifier across code, configs, CI, cron, monitoring, docs, env examples and sibling repos; proves the one safety fact; reports what each clearance rests on.
---
<!-- ported from cursor/plugins pstack (MIT) blast-radius, merged with CLAUDE.md rules D/D-GATE, memory feedback-blast-radius-sweep-on-every-change, feedback-fix-the-whole-defect-class, standard/rules/bash-ops.md; 2026-10-08 -->

# Blast radius

Listing callers is the easy part. The job is the breakage grep will not show. A writeup that sounds right is worthless: it reads as convincing whether or not it is true.

## 1. Inventory

List every touched identifier: fields, enums, routes, hosts, DB/project IDs, env keys, renamed or deleted symbols, shared predicates, wire formats. Read what the change now does differently, including what the diff does not spell out.

## 2. Sweep: one consolidated pass per change-set

All identifiers, all scopes: code, configs, CI workflows, launchd/cron, monitoring/alerts, docs, `.env.example`, sibling repos (`~/Desktop/projects/*`, incl. twins). Use `graphify query` and `ops/blast-radius.sh` for dependents, then plain `rg` for strings.
- **Never `| head` / truncate sweep output.** Page it or write it to a file and count.
- New FK on a tenant table: grep every delete/cascade handler and check `information_schema.referential_constraints` for `NO ACTION` children.
- Changed enum/type: every consumer, every render path (every datum needs UI).
- Two decisions gated by one predicate: confirm they want the same answer.

## 3. Find the one fact it is safe because of

Most risky changes are safe because of a single fact ("this only drops dead entries"). Name it, then prove it by the ladder below. Spend effort here, not on a long list of maybes.

## 4. Proof ladder, report the step reached per fact

1. You said so. Worthless alone.
2. You pointed at the line (`file:line`, or the library's own source via `srcof`).
3. You walked the failure step by step and it cannot reach.
4. You ran it: a script/test calling the real code that fails loud if you are wrong.
5. You reproduced it in the running app (staging/prod per rule F).

Unproven facts are written `unproven`, not rounded up.

## 5. Where grep stops

Dynamic dispatch, string-built keys (`` `cache:${kind}:${id}` ``), reflection/registries, DB columns and views, wire formats and other-language readers, feature flags, queue payloads in flight, external consumers (webhooks, mobile apps on old versions, client repos), code three hops downstream. Check each applicable one by reading the source or querying the live system.

## 6. Hand back

- **Result line (mandatory, verbatim shape):** `blast-radius: swept <ids> across <scopes> → clean` or `→ found + fixed N`. No line, not done.
- **The one safety fact** + ladder step reached + proof.
- **Risks**: how it breaks, `file:line`, likelihood, cost, cheapest check.
- **CLEARED** (separate section): one row per identifier or risk: `<id> | cleared by <evidence> | ladder step`. "grep found nothing" is step 2 at best, and only if the pattern was shown to match a known hit first.
- **Before merge**: the cheapest repro that catches the real bug.
