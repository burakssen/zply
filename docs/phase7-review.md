# Phase 7 audit and remediation

Date: 2026-11-18

## Status

**Original Phase 7: incomplete and not buildable.** The supplied source
referenced `task_lease` before it was declared in `src/parser.zig` and
contained two incompatible completion paths. In unordered mode,
`Parser.next()` queried a `Scheduler` whose window did not own the tasks
actually submitted by the parser's separate registry.

**Revised source: implementation corrections prepared; compilation and
runtime validation outstanding.** A Zig 0.17 compiler was not available in
the review sandbox. No `zig build` command was run successfully here; the
project must be compiled and tested in a Zig 0.17 environment.

## Key original defects

1. Referencing `task_lease` before its declaration and referencing fields
   absent from `DecodeTask` prevented compilation.
2. The parser's task registry could grow with `realloc`, moving a task whose
   address had already been given to a native future.
3. Concurrent decoding accessed `Pool.slots[id]`; growing the batch-slot
   array for retained leases could invalidate that metadata mid-decode.
4. The parser's unordered path polled an unrelated scheduler; it did not
   actually consume completions from the submitted tasks.
5. Task notification and cancellation were not part of one complete resource
   lifecycle; failure cleanup could attempt to cancel a published raw slot.
6. Read-ahead errors and successful-prefix batches were not consistently
   coordinated, and the benchmarking statistics did not measure actual
   concurrent decoder activity.

## Corrections included

- Stable, fixed-capacity generation-checked task registry (two outstanding
  tasks); no worker/thread configuration was added to Options.
- Value-only snapshots of output columns captured before dispatch, so native
  tasks never dereference a potentially relocated batch-slot table.
- One `Parser.next()` pipeline for task admission, reading, submission,
  completion, ordered/unordered delivery, and terminal error cleanup.
- Heap-owned completion queue with sufficient capacity for every admitted
  task, tagged by task slot, generation, and global sequence number.
- Native `std.Io.concurrent` submission for sufficiently large chunks and
  inline execution for small chunks or `ConcurrencyUnavailable`.
- Native future await/cancel, atomic cancellation checks at most 4096 records
  apart, and cleanup only after a task has been joined.
- Pre-read reservations for raw, column and task metadata; zero-property
  chunks avoid all scalar decode work; idle raw allocation reclamation.
- Metrics for submitted/rejected tasks, inline work, peak admitted chunks,
  and actual maximum simultaneously executing decoder tasks.
- Additional full-API integration tests for both byte orders, ordered and
  unordered delivery, fallback, failed read-ahead, early destruction, zero
  property elements, and element transitions.

## Validation to run

```sh
zig version                 # use a Zig 0.17.x toolchain
zig build test
zig build test -Doptimize=ReleaseSafe
zig build bench-concurrent -Doptimize=ReleaseFast
```

Recommended additional validation for a production release:

- Repeat test runs under alloc-failure instrumentation and race-sensitive
  tooling where supported by the runtime.
- Add deterministic, injection-controlled task completion permutations and
  decoder failures independently of wall-clock scheduling.
- Verify I/O and cancellation behavior with fragmented non-seekable readers.
- Expand concurrency integration coverage to mixed-width scalar layouts and
  3M–100M datasets at 16–256 MiB managed-memory budgets.
- Benchmark actual file-backed input, varied chunk sizes, multiple native
  executor capacities, and speedups relative to sequential decoding.

## Verified in this environment

- Source and original Phase 7 plan read directly from uploaded files.
- Internal source-level ownership and call-graph review performed.
- `git diff --check` passed (no whitespace or patch-format errors).
- A complete patched Git history and source archive were created.

**The above does not constitute compiler, race, memory-safety, or benchmark
validation.** Treat this as a remediation candidate, not a proven release.


## Follow-up audit (uploaded `zply(1).bundle`)

The follow-up Git bundle contains both `try parser.finishTask(...)` fixes. Those
are correct for the `NextError!?Batch` return type.

Additional hardening in this working copy:

- Completion-notification failures no longer disappear silently. A worker
  closes the affected completion queue and marks an atomic failure flag, so a
  waiting unordered collector can exit through its terminal cleanup path.
- The independent execution window now releases unpublished batch slots
  after failed tasks and after structured cancellation. Mixing ordered and
  unordered result consumption through one Window is explicitly rejected.
- Added a 3M-record end-to-end exact-once test, a mixed-width/f64 endian test,
  a retained-batch lifetime regression, and window-cancellation pool reuse.

**Important:** These source changes were not compiled or executed in the
review environment because Zig 0.17.1 was unavailable, and they do not
constitute final Phase 7 sign-off. Remaining required work includes
injection-controlled completion permutations and errors, injected completion
queue failure, non-seekable reader tests on the public concurrent path,
allocation/race stress testing, and performance scaling across executor
capacities, chunk sizes and memory budgets.
