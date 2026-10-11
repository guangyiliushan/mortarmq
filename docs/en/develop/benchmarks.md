# Benchmarks

How to read the performance numbers — the benchmark matrix, noise-control protocol, and the rules for drawing conclusions.

> **Status:** Skeleton — the smoke run lands before the full measurement. Unmeasured claims are never written up as conclusions. The `bench/` package is an empty shell today; the harness contract below is what it will implement.

## Benchmark Matrix

- Six size tiers: empty / 64 B / 1 KiB / 64 KiB / 1 MiB / 16 MiB
- Operations: encode / decode / copy
- Backends: native / wasm-gc (wasm-gc covers the pure core only)
- End-to-end: throughput + P50/P90/P99 (NSQ-style quantiles)

## Noise-Control Protocol (attach to every benchmark)

1. ≥ 10 rounds per configuration; report mean±σ (the `@bench.T` harness contract).
2. σ/mean > 3% voids the run (silence background load, then re-measure).
3. Differences < 5% support no optimization conclusion.
4. Windows: power plan = High performance, AC power, no battery saving; record the machine model in the environment column.
5. Microbenchmarks are treated as A/B tests: ±1% decisions require a significance calculation.

## Measurement Bars (the three decode assertions)

Three assertions define the decode performance bar, each judged on its own terms:

1. **Frame-layer decode stays in the 65–80 ns band.** The band comes from the 2026-09-30 frame-layer baseline (unloaded, 10 rounds per the noise protocol). Its domain of validity is the frame layer only — that is what gets archived.
2. **Decode cost does not grow with message size.** The zero-copy property: a decode borrows rather than copies, so the row stays flat across the size tiers.
3. **Full-path decode versus decode+copy: report the numbers, draw no conclusion.** Full-path figures land in the microseconds range and per-field allocation hotspots go to the performance memo. v0 schedules no optimization work; the numbers stand as measurements, not verdicts.

## Entry Template

```markdown
## BM-N: <name>
Environment: <CPU/RAM/disk/OS/power>  |  Version: <commit>
Noise control: <rounds> | mean±σ | σ reading
Method: <command + args + duration>
Results table: <P50/P90/P99/throughput>
Baseline: <previous version or competitor, same conditions>
Conclusion: ≤ 3 sentences; no verdict on differences < 5%
```
