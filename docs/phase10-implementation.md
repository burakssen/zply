# Phase 10 — Binary variable-length PLY: implementation log

Baseline: Phase 9 on `b9157f3`. The public reader and execution API do not change.

## Increment 1: compiled structural operations + pure binary scanners

This increment deliberately does **not** enable variable-length binary parsing
through `Parser.next()`. It provides independently testable foundations:

- `format/layout.zig` adds `PropertyLayout.binary_op`: compiled scalar widths
  and typed list count/item widths. Existing fixed-width decoding fields and
  manually constructed legacy test layouts remain compatible.
- `decode/binary/list_count.zig` interprets all six canonical integer count
  types with the declared byte order. Negative signed counts are rejected.
  The primitive has no memory allocation and does not read from `std.Io.Reader`.
- `input/binary_boundary.zig` walks declaration-order compiled operations
  over a borrowed record prefix. It returns either a complete record width
  with total item count, or a typed incomplete-input request (`property_index`,
  `stage`, `required_total`). Checked arithmetic enforces record/list limits
  before the corresponding payload is accessed.
- Optional `counts_out` contains per-property list item counts on complete
  scans (zero for scalars), without allocating a per-record count matrix.
- Both new test suites run in the default `zig build test` target.

The pure boundary scanner **may rescan** a prefix when called repeatedly with
more bytes. Milestone 2 uses bounded growth and repeats structural checks
without parsing payload values. A later throughput optimization may retain
a per-property cursor to avoid repeating even these structural checks.

## Subsequent work (not yet implemented)

1. A bounded, stateful variable-record scanner for a borrowed and non-seekable
   `std.Io.Reader`, with partial count and payload recovery.
2. Complete-record chunk assembly, including exact record boundaries and
   accurate byte offsets after element transitions.
3. Aggregated per-list output sizing, memory admission, prefix splitting,
   and the typed binary-variable decode kernel.
4. Dispatch through the existing native `std.Io` task system, ordered and
   unordered delivery, cancellation, fault injection, and large benchmarks.

Do not mark Phase 10 as complete until each of these is implemented and
validated in Debug and ReleaseSafe builds.

## Milestone 2 — Incremental binary variable record reading

`src/input/binary_variable.zig` adds an internal, non-seekable record reader
around the pure boundary scanner from Milestone 1. Each incomplete structural
scan supplies the minimum required record extent. The reader grows its own
scratch in bounded increments **before** reading more bytes, and consumes no
lookahead from the next record. Counts and list payloads may be fragmented
across arbitrary underlying reads.

When scratch growth returns `OutOfMemory`, the reader retains all already
consumed bytes and the record's starting body offset. The same reader can
resume the record with additional allocation capacity; the parser will later
provide its budgeted allocator and determine whether pressure is temporary
or permanent. The reader itself does not submit work or own batch leases.

Physical `body_bytes_consumed` includes partial records, while
`completed_body_bytes` and `completed_record_count` advance only after a
complete, validated record. EOF during scalar, list-count, and list-payload
reads receives a distinct truncation error. Malformed input and I/O failures
are terminal for the internal reader; memory-pressure errors are retryable.

The initial version favors exact-once correctness over bulk read speed by
using `std.Io.Reader.takeByte()` after reserving the destination. Future
pipeline integration may use a short-read bulk path only if partial-error
byte accounting remains exact. This milestone does not yet change
`Parser.next()`, public error mapping, or concurrent binary list support.

## Milestone 3 — Variable-length binary record-aligned chunks

`input/binary_chunk_builder.zig` combines complete binary variable-width records
from the incremental reader into a bounded staging chunk with indexed record
boundaries and checked per-property list totals. The builder owns the reader;
its `Chunk` view is borrowed until `consume`. First-record byte offsets are
physical body offsets and survive element transitions and staged pending
records. `synchronizeBodyOffset` permits safe counter handoff from an external
fixed-width element producer without seeking or discarding partial input. The first record can exceed the preferred chunk target, subject to
hard scanner and allocator limits. A following record that would overflow the
target remains in the reader's scratch without seeking.

Both structural input and per-property metadata allocations are made with
the caller-supplied allocator, permitting the parser's existing budget wrapper
to account for all retained capacities. A new `readRecordWithCounts` entry
point reuses the scanner's final per-property count results instead of
rescanning a complete record. If allocation pressure interrupts a read or
an append, all bytes already consumed and completed records remain owned;
the caller retries with the same source and builder after reclaiming memory.

This milestone remains internal: no changes to Parser.next(), output admission,
typed binary list decode, or scheduling yet.

## Milestone 4 — Output preflight and typed binary-variable decoding

`decode/binary/preflight.zig` checks a record-aligned chunk's boundary
metadata and computes exact scalar payload, per-list typed values, and
`record_count + 1` offset-array bytes. This is an allocation-free sizing
step over the **trusted** chunk builder result; it does not parse numerical
payloads again. Pool metadata and temporary capacities must be charged by
normal admission when this kernel is connected to `Parser.next()`.

`batch/storage.zig` provides `acquireBinaryVariableSized` and
`decodePreparedBinaryVariable`. The preparation call reuses the existing
list-column storage and explicit batch leases. The decoding kernel receives
only a captured `Pool.Target`, immutable bytes/boundaries/schema, and an
optional cancellation flag. It decodes mixed scalar and list properties in
schema order for either byte order and never accesses the Reader or allocator.
The worker independently checks count fields, precise boundaries, final list
totals, destination capacities, and cancellation (including inside long
list-item loops). No partially decoded batch is published on error.

`tests/binary_variable_decode_test.zig` exercises mixed scalar/list chunks
with empty lists in both byte orders, preflight sizing, invalid boundaries,
capacity mismatches, cancellation, all eight list-item scalar types, and the
bit patterns of negative zero and a NaN payload. This remains a standalone
internal component, **not** a `Parser.next()` binary-list implementation.

Remaining: bounded admission and chunk-prefix splitting, task integration
through the existing native `std.Io` machinery, parser-facing diagnostics,
element transitions, concurrency/fault-injection tests, and benchmarks.

## Milestone 5 — Public Parser.next and native binary-variable tasks

The public binary path now routes each compiled list-bearing element through
`binary_chunk_builder.Builder`, while retaining the existing fixed-width
producer for scalar-only elements. The builder owns every partially consumed
record and deferred terminal reader error; valid earlier records are delivered
before a later malformed or truncated record is reported.

The admission path preflights an exact record-aligned prefix, duplicates its
immutable bytes/boundary index/list totals, prepares typed output in the shared
pool, and submits a stable registry task through the caller's `std.Io`.
Both native concurrent execution and inline fallback share the completion,
ordered/unordered delivery, task cancellation, and lease lifetimes. The
staged chunk shrinks only after all input/output/task allocations succeed.
A failed admission never rereads or drops a consumed binary record. Under
budget pressure the parser evicts idle cached output, reduces prefix sizes,
then returns retryable pressure if outstanding leases prevent progress.

`tests/binary_variable_parser_test.zig` covers both byte orders, completion
policies, split chunks, trailing unread bytes, fixed-variable-fixed element
transitions and a terminal truncation behind valid-prefix output.

Remaining work includes comprehensive allocation/race/reader-fragmentation
coverage, performance benchmarks, and optimization of the incremental
byte-at-a-time scan. This milestone is not full Phase 10 sign-off.

## Milestone 6a — buffered binary list input and validation

- The variable-width binary reader now copies available `std.Io.Reader`
  buffered spans through `peekGreedy(1)` and `toss(n)` instead of calling
  `takeByte()` for every scalar/count/item byte.
- All copies remain bounded by the next structural scanner requirement and
  the reader's existing 4 KiB scratch growth policy; they never consume data
  from the following record. No public API or scheduler changes are needed.
- Unlike a bulk `readSliceShort()` call, the buffered-span path commits progress
  only after a successful copy. Truncation and source failures retain exact
  consumed-prefix diagnostics and respect the existing retry-on-OOM contract.
- Added large-payload/endian/fragmented-EOF regression tests and a dedicated
  end-to-end variable-list benchmark. Full fuzzing, broader failure-injection,
  and performance tuning remain open; do not mark Phase 10 complete yet.

## Milestone 6b — memory/concurrency hardening and staging profiling

`tests/binary_variable_hardening_test.zig` adds independent end-to-end
fixtures containing two list properties with different cardinalities,
interleaved with a scalar. Fragmented non-seekable input is verified for both
byte orders and both delivery policies under a constrained memory budget.
Every record ordinal, scalar value, list length, list item, trailing unread
byte, and peak total budget is checked. Separate tests exercise native
threaded ordered/unordered completion, terminal truncation behind complete
prefixes, early parser destruction while asynchronous work may be outstanding,
and a single list record larger than the preferred chunk size.

The `bench-binary-variable` benchmark now reports a distinct **record-aligned
chunk assembly** measurement between allocation-free structural scanning and
full `Parser.next()`. It separately verifies staged input byte counts and
aggregate list-item totals, and reports copied buffered spans and batch-size
reductions alongside throughput. This clarifies the sequential producer cost;
no timings should be interpreted as isolated numerical decoding cost. Input
fixture generation and compiled layout construction are outside the measured
interval. This is diagnostic instrumentation, not a scheduler/API change.

Remaining sign-off work: local Zig 0.17.1 validation, failure-injection and
coverage-guided fuzzing, and high-scale memory/performance measurements on the
target machine. Keep existing Phase 7/9 benchmark baselines for regressions.

## Phase 10 Milestone 6D — differential fuzz-style validation and cancellation checkpoint

- `tests/binary_variable_final_test.zig` compares the compiled binary record
  scanner against an independent hard-coded reference state machine for
  60,000 deterministic valid, truncated, mutated-count, arbitrary and
  trailing-byte prefixes, split between both byte orders. The seed is fixed
  for reproduction. This is **differential randomized testing**, not a
  completed coverage-guided fuzzing campaign against external PLY readers.
- The existing internal `list_item_checkpoint` test hook also fires within
  binary-variable list decoding at 4096-item boundaries. A deterministic
  `DecodeTask` test requests cancellation from the checkpoint and verifies
  the task returns `Cancelled`, retains unpublished output, and permits
  subsequent pool reuse and successful decoding. Production builds compile
  out the hook branch; no public API changes were made.
- An opt-in `bench-binary-variable-matrix` command sweeps 64/256/1024 KiB
  preferred chunks, 16/64/256 MiB budgets and threaded ordered/unordered
  delivery on little- and big-endian triangle/mixed-polygons workloads. It
  checks decoded checksums, total records and items, and peak parser budget
  on every measured run. Fixture generation is excluded from timing.
- Existing allocation-injection, fragmentation, retained-lease, early
  teardown, and 3M/10M virtual-reader tests remain part of the baseline.

To run (Zig 0.17.1):

```sh
zig build test
zig build test -Doptimize=ReleaseSafe
zig build test-binary-variable-large -Doptimize=ReleaseFast
zig build bench-binary-variable -Doptimize=ReleaseFast
zig build bench-binary-variable-matrix -Doptimize=ReleaseFast
```

The matrix is optional because it executes many complete parsing runs.
Coverage-guided fuzzing and independent third-party real-world PLY reader
comparisons remain recommended for production sign-off.

## Phase 10 production assurance — coverage-guided fuzz harness

The latest validation run passed the 60,000-case deterministic reference
comparison, large-list cancellation, 3M/10M virtual-reader tests, and the
chunk/budget benchmark matrix. These are a baseline, not a substitute for a
coverage-guided fuzz campaign.

Two additional Zig 0.17.1 `std.testing.fuzz` targets reuse the *independent*
reference state machine in `binary_variable_final_test.zig`:

- **raw:** arbitrary 0–255-byte structural records, including malformed count
  fields and truncated inputs.
- **structured:** small valid list counts and real list payloads, with modes
  for truncation, trailing bytes, and count mutation to reach deeper branches.

Each fuzz iteration checks both the pure compiled-layout record scanner and
its incremental `std.Io.Reader` assembler. Complete records must consume
exactly the declared record length, retain the bytes verbatim, and preserve
trailing input; incomplete records must return stage-specific truncation
errors; permanently invalid counts must produce the reference error. Input
length is capped at 256 bytes and the record limit at 256 bytes.

Smoke-replay the inline corpus without fuzzing:

```sh
zig build fuzz-binary-variable
```

Run coverage-guided searches (one selected target at a time):

```sh
zig build fuzz-binary-variable -Dfuzz-filter="fuzz raw" --fuzz=100K
zig build fuzz-binary-variable -Dfuzz-filter="fuzz structured" --fuzz=100K
```

`--fuzz=N` is a finite search budget, **not** a claim of complete coverage.
Inspect the fuzz command output for findings and persist any minimized
crashing corpus input as a dedicated regression test. Zig 0.17.1 may report
fuzzer findings without a nonzero process exit status; do not judge success
only by the shell exit code.

These targets do **not** exercise the entire Parser, native task scheduler,
all list-count types, arbitrary schemas, or external interoperability. Those
remain separate hardening work. The new opt-in build step does not change the
public API or parsing implementation.
