# Phase 12 M2 — Unified benchmark harness

## Scope

The new `bench-phase12` step provides a single, **end-to-end** measurement
protocol for the seven independently generated and verified Phase 11 workloads.
Its generator and typed-column consumer are reused, not copied; the legacy
`bench-phase11` step and its 28-row comparison contract remain available.
Future M3 work will add wide records, mixed schemas, varied numeric text,
real-world fixtures, and larger datasets using the same reporting layer.
Microbenchmarks and production-path stage instrumentation remain distinct.

**No changes to `zply.Parser`, `std.Io` scheduling policy, allocation budgets,
or decoding kernels are intended.** The harness uses Zig 0.17.1 native
`std.Io.Threaded` and memory-backed `std.Io.Reader`; it does not add a parser
worker setting.

## Run

From the standalone repository root:

```sh
zig build test-bench-harness -Doptimize=ReleaseSafe
python3 scripts/test_check_phase12_capture.py

# Full matrix, 3 warmups + 15 measured runs per workload/mode:
zig build bench-phase12 -Doptimize=ReleaseFast 2> phase12-baseline.csv
python3 scripts/check_phase12_capture.py phase12-baseline.csv --require-full-matrix

# Quick correctness smoke run; uses only one workload/mode:
zig build bench-phase12 -Doptimize=ReleaseFast -- \
  --workload=binary_xyz_f32 --mode=single-ordered \
  --records=10000 --warmups=1 --rounds=3 2> phase12-smoke.csv
python3 scripts/check_phase12_capture.py phase12-smoke.csv
```

The executable writes CSV to **stderr** with `std.debug.print`, matching
Phase 11 conventions. Build progress may precede the CSV header. Keep stdout
for unrelated build-system output; the reader locates the exact header.

Supported flags: `--workload=`, `--mode=`, `--records=`, `--chunk-bytes=`,
`--small-chunk-bytes=`, `--budget-bytes=`, `--warmups=`, `--rounds=`, `--help`.
All flags use bytes for sizes; no implicit KiB/MiB conversion occurs. The
full matrix covers seven encodings/layouts and four execution modes.
Threaded workloads require at least one actual native decoder submission;
very small inputs may fail this guard, so use single mode for smoke runs.

## Measurement protocol

Two monotonic wall-clock timing scopes are recorded for *every* trial:

- **Body** begins immediately before the first `Parser.next()` call and ends
  immediately after final iteration and all batch releases. It includes the
  complete typed-column validation consumer/digest, scheduling, and logical EOF
  handling; it excludes initialization and destruction.
- **Lifecycle** begins before `Parser.init()` and ends after `Parser.deinit()`.
  It includes everything in the body scope, schema compilation, initialization,
  destruction and shutdown. It excludes fixture creation, executor setup,
  statistics aggregation and CSV printing.

Samples are collected with 3 warmup rounds and 15 measured rounds by default.
Execution order rotates between selected modes each round to reduce systematic
cache bias. There is no configured random seed because fixture values and
round order are deterministic. `sample` rows preserve all individual measured
latencies; one `summary` row per workload/mode provides median and nearest-rank
p05/p95 for each of the two scopes. The even-number-of-rounds median is the
upper middle order statistic. Percentiles describe the observed trial sample,
not confidence intervals.

All throughput fields are based on **lifecycle** median on summary rows and
lifecycle wall time on sample rows. `input_gbps` uses decimal GB/s and body
bytes only, excluding the PLY header. `list_items_per_s` is zero for
scalar-only workloads. `parser_peak_bytes` is the maximum across measured runs
on summaries, rather than merely the most recent run. Native/inline scheduling
metrics and batch count describe the last measured run in each summary.

Every run checks the exact record count, list-item count, column shape,
order-independent logical-record digest, and parser peak-memory limit *before*
reporting. Digest hashing includes the **logical record index**, preserving
content identity across unordered delivery. A digest match is a strong
regression check, not cryptographic proof of correctness. The full Phase 11
regression and fault-injection suite remains required.

## Report schema

`row_type` is `sample` or `summary`. `round` is zero-based for samples and
`-1` for summaries. All rows carry the same exact column header:

```text
row_type,workload,mode,records,body_bytes,list_items,chunk_bytes,budget_bytes,warmups,rounds,round,lifecycle_ns,body_ns,lifecycle_p05_ns,lifecycle_p95_ns,body_p05_ns,body_p95_ns,records_per_s,input_gbps,list_items_per_s,parser_peak_bytes,batches,native_submissions,inline_decodes,max_active,digest_sum,digest_xor
```

Digest fields are lowercase hexadecimal. The CSV validator rejects absent
samples, missing rounds, mismatched fixtures, inconsistent percentile values,
incorrect memory counters or purported threaded runs without native tasks.
It can require all 28 workload/mode combinations. Run
`python3 scripts/test_check_phase12_capture.py` to test the validator itself.

## Reproducibility and next milestone

Keep benchmark captures alongside `git rev-parse HEAD`, `zig version`, OS,
CPU, native executor configuration, compiler optimize mode, and memory budget.
Avoid comparing captures from dissimilar machines or compiler versions.
The `phase11-current.csv` format is deliberately unchanged, and the Phase 11
comparator must **not** be used directly on Phase 12 `sample`/`summary` rows.

M2 establishes the harness and report protocol; M3 extends the workload and
fixture matrix before Phase 12 M4 records the pinned baseline. No throughput
improvements or regressions are claimed by adding this infrastructure.
