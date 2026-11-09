# Workers logs at 100% sampling with Logpush

Pack: observability, cloudflare | Probe type: S | Source: Ebda AI Studio audit 2026-10-26 OPS-23

## Claim
Full-rate logs plus Logpush on every Worker is a metered cost with no usage alert; sample and alert on spend.

## Scenario
Ebda ran 100% Workers Logs and Logpush on every Worker with no usage alert verified.

## Source candidate
- (low) wrangler config logs at 100% sampling or enables logpush.

The probe is a bounded lexical check. It reports candidates with file/line evidence and does not claim that a local guard name proves the guard is effective. A judge must read the code behind every hit (reachability, middleware, framework semantics) before grading.

## Fix template
Set head_sampling_rate below 1 for high-volume Workers and add a usage alert.

Score 0: verified reachable unsafe behavior. Score 1: candidate exists but reachability/mitigation is unresolved. Score 2: inspected path has effective protection. N/A: no applicable source.
