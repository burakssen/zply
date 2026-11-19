# Phase 12 M1 — Benchmark audit and timing contract

## Purpose and audited source

This is the **measurement-foundation audit**, not a speed optimization or a
new benchmark harness. Audited at Git commit `026a91e` with Zig build targets
from `build.zig`. There are **11** benchmark entry points. The exhaustive,
machine-readable inventory is [`../../benchmarks/audit.json`](../../benchmarks/audit.json).

The Phase 11 M16 benchmark (`bench-phase11`) is the best existing **interim
end-to-end reference** because it validates records, list item counts, a
content digest, and the 16 MiB parser budget, and emits a common CSV schema.
It is **not yet the Phase 12 baseline**: it has seven small workloads, measures
only complete lifecycle time, and retains only aggregate quantiles, not raw
per-round measurements. Capture a new, pinned baseline in M4 after M2–M3.

## Classification of every existing benchmark

| Build target | Source | Scope | Timed operation | Trials / statistic |
| --- | --- | --- | --- | --- |
| `bench` | `binary_decode.zig` | Micro | In-memory fixed-layout decoding + scalar checksum; no reader/parser | 5 measured, best |
| `bench-streaming` | `streaming.zig` | Mixed pipeline | Chunk producer, raw record decode, or typed columns; parser initialization excluded | 3 measured, best |
| `bench-columns` | `columns.zig` | Mixed pipeline | Generic records vs direct/property-major columns vs `next()`; setup excluded | 3 measured, best |
| `bench-concurrent` | `concurrent_decode.zig` | End-to-end | Full parser lifecycle + decoded-value digest | 3 warmup, 15 measured, median/p05/p95 |
| `bench-ascii-numbers` | `ascii_numbers.zig` | Micro | Separate integer, float, tokenizer intervals | 1 sample per operation class |
| `bench-ascii` | `ascii_streaming.zig` | End-to-end | Full ASCII parser lifecycle + numeric sum | 2 warmup, 7 measured, median |
| `bench-ascii-concurrent` | `ascii_concurrent.zig` | End-to-end | Full ASCII parser lifecycle + numeric sum | 2 warmup, 5 measured, median |
| `bench-binary-variable` | `binary_variable_pipeline.zig` | Mixed pipeline | Structural scan; chunk assembly; or complete parser lifecycle | 2 warmup, 5 measured, median |
| `bench-binary-variable-matrix` | `binary_variable_matrix.zig` | End-to-end | Complete binary-list parser lifecycle across budget/chunk grid | 1 warmup, 3 measured, median |
| `bench-phase11` | `phase11_performance.zig` | End-to-end | Full parser lifecycle + decoded-value digest and validation | 2 warmup, 9 measured, median/p05/p95 |
| `bench-phase12` | `main.zig` / `harness.zig` | End-to-end | Unified lifecycle/body timing with validation or minimal consumer | 3 warmup, 15 measured, median/p05/p95 + raw rounds |

**Classification rules:** "micro" isolates primitive token/scalar operations;
"pipeline" isolates one or more production stages without the public parser
lifecycle; "end-to-end" includes `Parser.init`, the entire `next()` stream,
and `Parser.deinit`; "mixed" provides multiple non-equivalent modes in one
executable. Some mixed targets have an end-to-end mode, but the entire target
must not be treated as a single homogeneous benchmark.

All entries use monotonic `std.Io.Clock.awake` timing and deterministic
memory-backed fixtures; **none measures cold filesystem reads**. Raw source
creation is outside timed regions. The source files, not this table, remain
authoritative when a benchmark implementation changes.

## Differences that currently invalidate direct comparisons

1. **Timing scope:** `bench-streaming` and `bench-columns` initialize the
   parser before starting the timer, while most newer end-to-end targets
   time initialization and cleanup. Do not compare their reported ns/record.
2. **Unequal output work:** `bench-streaming`'s producer mode hashes a few
   raw chunk bytes instead of decoding every value; `bench-binary-variable`'s
   structural modes validate boundaries rather than materializing columns.
   A higher throughput number does not imply a faster complete parser.
3. **Different result checks:** checksum is bitwise XOR, order-independent
   logical digest, FNV-like hash, or a floating numeric sum depending on the
   target. Comparisons must use the *same* logical validation procedure.
4. **Different statistics:** best-of-3/5, single sample, and median over
   3–15 samples should not be interpreted interchangeably.
5. **Fixture size and composition:** an 8 MiB scalar decode, 250k mixed-format
   records, and 3M XYZ records exercise different costs and CPU cache states.
6. **Executor and memory configuration:** native thread capacity, chunk size,
   memory cap, ordering mode, and allocator vary between benchmarks. Record
   them in each comparable result, rather than relying on benchmark names.
7. **Metrics:** `bench-streaming` reports raw-buffer capacity, not parser peak
   live-plus-reserved memory; allocation counts and peak capacities are
   separate, non-interchangeable memory measures.
8. **Steady-state vs lifecycle:** the older pipeline-oriented tests don't
   measure complete setup/cleanup, while the M16 CSV does not separate body
   time. Avoid using their difference as an estimate of startup cost.

### A known benchmark validity caveat

In `bench-streaming`, the outer loop combines per-trial checksums with XOR
(`digest ^= ctx.checksum`). Because exactly three trials run, the final
reported digest may happen to match a single trial, but it is not independently
checked against a reference dataset. Treat that result as a diagnostic only,
not as authoritative full-value validation. Do not alter its behavior during
M1; M2–M3 can replace it with a consistent independently checked digest.

## Official Phase 12 timing contracts (for M2)

The unified harness **must record two separate timings** on the same input:

**A. Steady-state body processing (`body_ns`).** Construct the parser and
compile the header **before** starting the monotonic timer. Start immediately
before the first `Parser.next()`. Stop after the final null return, including
any consumer digest, batch release, task synchronization, and error checking
that occurs during the stream. Exclude `Parser.init()` and `Parser.deinit()`.

**B. Complete parse lifecycle (`lifecycle_ns`).** Start immediately before
`Parser.init()` and stop immediately after `Parser.deinit()`. Include all
header/schema work, body processing, digest, native task completion and
cleanup. Exclude input generation, reading fixtures from disk into a benchmark
buffer, executor creation/destruction, and output/report formatting.

Do **not** calculate `lifecycle_ns - body_ns` from independently timed samples
as if it were a precise initialization or cleanup duration. Measure those
components separately if needed. Never sum overlapping producer/worker
stage durations as if they were elapsed wall time.

### Component/micro timing contracts

- **Micro (`kernel_ns`):** exclude input generation, schema construction,
  output allocation, and printing; include every kernel operation and its
  minimal observable consumer. Name the included operation and avoid a
  checksum dominating the measured computation.
- **Pipeline (`stage_ns`):** state exactly which stages execute, and whether
  input staging, output preflight, allocation, scheduling, and validation are
  inside the timer. Record stage overlap explicitly.
- **Input throughput:** `body_bytes / seconds / 1e9` (decimal GB/s). Include
  body bytes rather than header size only when declared as such.
- **Record throughput:** complete logical records / wall seconds. List-item
  throughput is separately measured for variable-length lists.
- **Memory:** report `peak_total_bytes` for the parser-managed budget, with
  live and reserved memory separated where available; do not label raw
  buffer capacity or OS RSS as the parser-managed peak.

### Reproducibility and verification (M2–M4 contract)

- Use `ReleaseFast`, native monotonic clock, deterministic self-authored
  fixtures; start with **3 warmup + 15 measured** rounds, varying these only
  with a documented reason and retaining every sample.
- Alternate/randomize baseline and candidate to mitigate CPU temperature,
  frequency scaling, memory cache warmup, and background scheduling effects.
- Record Git commit, Zig version, OS/architecture/CPU, execution backend,
  input fixture hash, logical schema, record/list counts, chunk size, memory
  budget, order, allocator, number of trials, and consumption mode.
- Validate exact record/list counts, bitwise or otherwise independently
  specified digest, monotonic list offsets, no skipped batches, and peak
  parser-managed memory under the configured budget **outside** the timer
  when that avoids a biased measurement (but still validate every trial).
- Store every raw duration, not just aggregated quantiles, and report
  median/p05/p95 with the declared percentile rule.
- Keep minimal-consumer throughput separate from full-validation correctness
  runs. A minimal consumer must still make decoded work observable.
- Never compare results across unlike workload/input/consumer/timing modes.
  `phase11-current.csv` is useful historical context only. Do not invent a
  Phase 10 baseline by relabeling Phase 7–10 measurements.

## M1 verification and handoff

Run from the standalone repository root:

```sh
python3 scripts/check_benchmark_audit.py
python3 scripts/test_check_benchmark_audit.py
```

The check ensures every `benchmarks/*.zig` entry point has an inventory row,
each target is registered in `build.zig`, and critical scope/timing fields are
nonempty. **It does not assert performance or execute Zig.** M1 makes no
production parser or benchmark timing changes; M2 will create the common
harness and M3 will expand the workload matrix.
