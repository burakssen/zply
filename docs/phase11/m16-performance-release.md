# Phase 11 M16 — performance verification and release readiness

## Design and scope

The new `bench-phase11` target runs an end-to-end `Parser.init -> next ->
release -> deinit` benchmark. It does **not** change the production parser
or its public API. All inputs are generated in memory **before timing**, so
figures exclude disk I/O and fixture generation. They **include** parser
initialization/destruction, structure validation, chunk production, typed
column materialization, digest calculation and batch release. The digest
prevents a benchmark from rewarding dropped or corrupted records.

Workloads (250,000 records each):

| Workload | Decoder path | Metrics to inspect |
| --- | --- | --- |
| `binary_xyz_f32` | binary little-endian 3 × f32 | records/s, input GB/s |
| `binary_xyz_f64` | binary little-endian 3 × f64 | records/s, input GB/s |
| `binary_xyzrgb` | binary little-endian 3 × f32 + 3 × u8 | input GB/s |
| `binary_polygons_le` | variable-length i32 list + u16 (LE) | list items/s, GB/s |
| `binary_polygons_be` | variable-length i32 list + u16 (BE) | list items/s, GB/s |
| `ascii_xyz` | 3 decimal f32 tokens | numeric token throughput: records/s × 3 |
| `ascii_polygons` | varied ASCII list lengths + u16 | records/s, items/s |

Each workload uses the same **2 warmup + 9 measured rounds** across four
modes: single ordered, native threaded ordered, native threaded unordered,
and single ordered with **8 KiB** chunks instead of **256 KiB**.
The external `std.Io.Threaded` executor has a concurrency limit of four;
no worker configuration is added to the parser itself.

The benchmark rotates mode execution order to reduce systematic cache bias.
It reports *median*, *p05*, *p95* (nearest-rank), records/s, input GB/s,
list items/s, parser peak bytes, batches and native/inline execution counts.
The reader sees the exact same source in all four modes. Input generation is
outside the timer; all checksum work is inside it. Every measured sample must
match the expected digest, record count and list item count. The parser's
`peak_total_bytes` must remain <= 16 MiB, including when native work runs.

The CSV contains **28 rows** with a stable header and exact fixture identity
fields, and can be compared programmatically. Threaded modes must actually
submit native tasks; otherwise the run fails rather than reporting fallback
as a concurrency benchmark. Large memory-allocation stress
and correctness are still covered separately by M12–M15 tests; this is not a
substitute for those checks.

## Reproducible local capture

Run at the **Git repository's `zply/` build directory**, using Zig 0.17.1:

```bash
zig fmt benchmarks/phase11_performance.zig
zig build test -Doptimize=ReleaseFast
python3 scripts/test_compare_phase11.py
zig build bench-phase11 -Doptimize=ReleaseFast 2> phase11-current.csv
```

The standard library's `std.debug.print` writes CSV to stderr. Zig build
progress may precede the CSV header; the comparison tool intentionally skips
non-data lines. Never capture a partial run as a valid result; inspect the
exit status and confirm all **28** workload/mode rows are present.

Record the machine and toolchain with each capture:

```bash
uname -a > phase11-environment.txt
zig version >> phase11-environment.txt
git rev-parse HEAD >> phase11-environment.txt
```

The GitHub Actions `zply-performance.yml` workflow performs a **manual**
Linux/macOS capture and stores CSV and environment information as artifacts.
Shared CI runners are appropriate for build correctness and trend exploration,
but their timings are too variable to establish an automatic cross-run
performance gate without a controlled machine.

## Historical comparison — do not fabricate a Phase 10 baseline

The M16 benchmark and comparator **did not exist in Phase 10**. Historical
Phase 7–10 benchmark numbers use different fixtures, workload sizes and
sometimes different timing scopes; they are **not** interchangeable with M16
CSV rows. To assess *Phase 10 vs Phase 11* specifically, port the exact M16
benchmark harness (including its build registration) to a **separate Phase 10
worktree**, without porting production parser changes. Then build the two
revisions with the same Zig compiler, hardware, benchmark constants and
ReleaseFast mode, capture each, and run:

```bash
python3 scripts/compare_phase11.py phase10-baseline.csv phase11-current.csv --require-full-matrix
```

Only use comparison if both sides contain identical workload/mode keys,
record counts, body sizes, list items, chunk sizes, budgets, measured-round
counts and content digests; the comparator rejects a mismatch. If the Phase 10
parser cannot run an M16 fixture or does not expose the required API, document
that limitation and **do not claim** a numerical regression or speedup.

For a *current Phase 11* regression baseline, capture two verified commits
that both contain this benchmark. The default policy flags **>15% median
latency growth** or **>10% parser peak memory growth** for any comparable
workload. Change these via `--max-median-regression-pct` and
`--max-peak-growth-pct`, or use `--warn-only` to investigate without failing.
These are **review thresholds, not statistical significance tests**: repeat
on an otherwise idle machine, investigate noisy runs and profile hot paths
before changing decode logic. p05 and p95 are always reported as diagnostic
context, not used alone as a failure gate.

## Final release checks

1. Debug, ReleaseSafe and ReleaseFast unit/integration suites pass.
2. `zig build test-regression`, `test-faults`, `test-concurrency`,
   `test-ownership-memory` and `test-stress -Doptimize=ReleaseSafe` pass.
3. Relevant bounded fuzz targets and known bug reproducers pass.
4. `python3 scripts/test_compare_phase11.py` passes.
5. `zig build bench-phase11 -Doptimize=ReleaseFast` succeeds with 28 valid
   rows, matching digests, bounded memory and verified native submissions.
6. Comparable before/after measurements are captured on a controlled host,
   regressions are reviewed and any targeted optimization retains correctness
   and memory-budget safety.
7. GitHub-hosted CI and target-platform testing have been observed to pass;
   **adding a workflow file is not evidence of CI success**.

**Status:** This change supplies the instrumentation and regression gate.
No new throughput numbers or confirmed historical performance comparison
are claimed until the executable is run and a real baseline is captured.
