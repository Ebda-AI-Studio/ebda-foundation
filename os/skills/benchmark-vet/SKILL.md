---
name: benchmark-vet
description: Use before reporting or acting on a MEASURED number (k6 p95, load test, speedup, regression, cost or usage figure). Not for static claims. Returns VERIFIED, NOT VERIFIED or INCONCLUSIVE with the evidence.
---
<!-- ported from cursor/plugins pstack (MIT) principle-explain-the-number + benchmark-checklist and cursor-team-kit verify-this, merged with CLAUDE.md rules 3 and F, standard/deploy-verify.md; 2026-10-08 -->

# Benchmark vet

A run that went wrong still prints a plausible number: failed requests are fast, so p95 *improves* when the server errors. If you cannot say why the number is not twice as good, you do not know what you measured.

## 1. State the claim falsifiably

Write the sentence you would ship: condition, metric, threshold ("checkout p95 < 500 ms at 50 VUs on staging, 0% errors"). Read the measurement script: what it times, counts, ignores. Name the environment (machine, `uptime`, `sysctl -n hw.ncpu`, versions, data size, region). A busy machine: interleave the sides and say so.

## 2. Answer each question with evidence from a run

1. **Errors**: error/non-2xx rate reported *next to* latency. A p95 over failing requests is meaningless; any non-zero rate means NOT VERIFIED until explained. Check outputs are correct, not just present.
2. **Did the work happen**: requests reached the server, rows written, bytes read. Unawaited promises, cached hits and no-ops produce numbers for work never done.
3. **Warmup**: cold start, JIT, pool and cache fill excluded or reported separately; warm as production sees it.
4. **Sample size and spread**: at least 5 runs per side, alternating A B A B; report median and range. A gap inside run-to-run variation is no difference. For latency, enough requests that p95/p99 rest on more than a handful of tail samples.
5. **Baseline**: same command, data, warmup and environment on the old state (merge base, parent commit). No baseline means INCONCLUSIVE.
6. **Why not double**: name the limiter (CPU, lock, disk, network, pool, the load generator itself) from a profile or counters, not from reading code. Use `top`/`pidstat`, `node --cpu-prof`, `py-spy`, `EXPLAIN ANALYZE`; profile in an unreported run.
7. **Limits arithmetic**: bytes/s vs link, ops/s vs cores, time saved vs time the changed piece took (removing 10% of a run gains at most ~11%). Past a limit means you measured something else.
8. **Tuned, and matters**: every side runs as production runs it (release build, prod flags, pool settings; **managed Postgres: Hyperdrive/pooled, not a cold direct branch**). Micro results are stated as a share of the end-to-end path.
9. **Cost / usage figures**: reconcile against the provider's own invoice or dashboard for the same window; state the unit and period.

## 3. Verdict (exactly one, do not soften a negative)

- **VERIFIED**: moved the predicted way past the threshold, zero unexplained errors, limiter named, no confound.
- **NOT VERIFIED**: unchanged, wrong direction, threshold missed, or errors present.
- **INCONCLUSIVE**: no valid baseline, noisy signal, untuned side, failed measurement, environment difference, or Q1/Q2 unchecked. Name the gap and what would settle it (rule F's "what I could not verify").

```
VERIFIED | NOT VERIFIED | INCONCLUSIVE
Claim: <falsifiable claim>
Evidence: <metric> baseline=<..> treatment=<..> delta=<..> threshold=<..> errors=<..> runs=<n, range>
Environment: <named>   Limiter: <named>
Gaps: <what was not verified, and why>
```

Keep the primary number in the PR body; put runs and limiter evidence in a linked file.
