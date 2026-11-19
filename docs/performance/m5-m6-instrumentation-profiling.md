# Phase 12 M5–M6 — Attribution and CPU profiling workflow

## Current low-overhead observability

The end-to-end harness records parser-owned peak allocation, batch count,
native submissions, inline decoding fallbacks, and maximum active decoders.
These measurements distinguish admitted work from actual native decode activity
without adding timestamps to scalar/token loops. The CSV reports wall-clock
body and lifecycle durations separately; they must not be added to task or
stage durations.

For a detailed hot-path investigation, use a sampling profiler. Sampling adds
far less distortion than per-scalar timing and preserves the public parser API.

## Build a profiler-friendly benchmark

```sh
zig build install-bench -Doptimize=ReleaseFast
```

The benchmark module leaves Zig's `strip` setting unset, so an optimized
benchmark build retains symbol and DWARF information by default. Before
profiling, verify that the installed binary actually contains the expected
symbols on the target platform (for example, `nm -nm zig-out/bin/zply-bench`
on macOS). Do not pass `-Dstrip=false`: this project deliberately exposes no
such build option.

Run one long, representative workload rather than a short all-workload matrix.
For example:

```sh
zig-out/bin/zply-bench --workload=ascii_scientific --mode=threaded-ordered \
  --consumer=minimal --records=3000000 --warmups=3 --rounds=1
```

The reported results are only valid when the benchmark's fixture and consumer
digest complete successfully.

## macOS

Use Instruments Time Profiler or `samply` with the installed executable:

```sh
samply record zig-out/bin/zply-bench --workload=binary_xyz_f32 \
  --mode=threaded-ordered --consumer=minimal --records=3000000 --rounds=1
```

Record the workload, command, Git commit, Zig version, platform, top sampled
functions, and one falsifiable optimization hypothesis in a profile note under
`docs/performance/profiles/`. Do not retain only an image without its command
and metadata.

## Linux

```sh
perf record -g -- zig-out/bin/zply-bench --workload=binary_large_lists \
  --mode=threaded-ordered --consumer=minimal --records=3000000 --rounds=1
perf report
```

When profiling concurrent work, compare `native_submissions`, `inline_decodes`
and `max_active` in the CSV with thread activity in the profiler. A high task
admission count is not evidence of CPU parallelism.

## Attribution rules

- Use end-to-end CSV timings to identify which workload changed.
- Use sampling profiles to identify functions and call paths within that work.
- Treat task execution totals as overlapping work, not elapsed latency.
- Profile the baseline before changing a hot path; retain rejected hypotheses
  in the corresponding experiment note.
