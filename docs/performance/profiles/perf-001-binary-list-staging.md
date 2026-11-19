# PERF-001 — Binary variable-list staging

## Observation

The Phase 12 validation baseline captured on 2026-11-19 identified variable
length binary lists as a weak concurrency-scaling workload. On the same Apple
M2 Pro / Zig 0.17.1 configuration, `binary_large_lists` reached 51.576 ms
median body time in single ordered mode and 43.643 ms in threaded ordered
mode (about 1.18×). Its native execution high-water mark was one active
decoder despite 134 native submissions.

Apple Instruments Time Profiler was recorded with:

```sh
xctrace record --template 'Time Profiler' \
  --output /private/tmp/zply-perf-001-binary-large-lists-steady.trace \
  --time-limit 30s --no-prompt --launch -- \
  zig-out/bin/zply-bench --workload=binary_large_lists \
  --mode=threaded-ordered --consumer=minimal --records=3000000 \
  --warmups=1 --rounds=20
```

The trace was symbolized against `ReleaseFast` output with retained DWARF
information. The visible parser hot paths were, in descending sampled
frequency: `input.binary_chunk_builder.Builder.fill`,
`input.binary_variable.Reader.readRecordWithCounts`,
`input.binary_boundary.Scanner.scan`, `execution.task.DecodeTask.execute`,
and `batch.storage.Pool.decodePreparedBinaryVariableWithHooks`. Fixture
generation was present in the process but was a small portion of this
20-round trace; it is outside benchmark timing. The trace and its XML export
are intentionally retained in `/private/tmp`, not source control.

## Hypothesis and experiment

`Reader.readRecordWithCounts` grows a known list payload geometrically from a
small structural read. The hypothesis was that reading up to 4 KiB of a
validated payload at once would reduce reader interactions and speed list
workloads without changing bounded-memory retry behavior.

The candidate used a 4 KiB list-payload increment while retaining geometric
growth for scalar/count stages. It passed `zig build test -Doptimize=ReleaseSafe`
and a complete Phase 12 validation capture: all 64 workload/mode cases and
960 measured samples had matching validation digests and stayed within their
parser-managed memory budgets.

## Result and decision

The candidate was compared with the matching baseline using the full
validation consumer and body-time medians. It did not improve its target:

| Workload mode | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Large lists, single ordered | 51.576 ms | 52.201 ms | +1.21% |
| Large lists, threaded ordered | 43.643 ms | 44.245 ms | +1.38% |
| Multi-list, threaded ordered | 26.602 ms | 27.467 ms | +3.25% |
| Polygon LE, threaded ordered | 13.478 ms | 13.769 ms | +2.16% |

Peak parser memory was unchanged. The direct bulk-read modification is
therefore **reverted**. The geometric incremental reader remains the current
implementation. A future list experiment should separately measure allocator
growth and raw-buffer copying before altering the admission step again.
