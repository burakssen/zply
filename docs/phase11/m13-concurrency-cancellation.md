# Phase 11 M13 — Deterministic concurrency and cancellation

## Scope

M13 uses the existing `std.Io` task executor and the internal test-only
`fault_injection.Hooks`. No parser option, user worker count or public API is
added. Compile-time test hooks have no ordinary production effect.

`zig build test-concurrency` runs the deterministic scenarios independently.
They also participate in `zig build test` across Debug, ReleaseSafe and
ReleaseFast. Native `std.Io.Threaded` is configured with enough executor
capacity for the four gated tasks; this is not a parser worker setting.

## Deterministic completion ordering

For four binary fixed-width tasks with sequences `0,1,2,3`, the test gates
`before_notify`/`after_notify` with atomics and checks each of:

- `0,1,2,3`
- `3,2,1,0`
- `2,0,3,1`
- `1,3,0,2`

In **ordered** mode, delivery always remains `0,1,2,3` with exact values,
record starts and no duplicate records. In **unordered** mode, delivery
follows the actually enforced notification order. Every test verifies four
native submissions, complete task reclamation and budget invariants.

## Failure order and cleanup

A test-only `decode_failure(sequence)` callback injects an error *within*
a native worker, after that task enters `running` but before any output is
written. The normal `DecodeTask.execute` failure recording and completion
path applies. Separate sessions inject failures at the first, middle or
last task and at both sequences 2 and 3. When sequence 3 completes first,
ordered delivery still reports the sequence-2 failure after releasing the
successful prefix. Unordered mode reports the first completed failing task
under the configured notification order. Terminal errors leave no task
leases, pending reservations or published partial output.

A separate EOF test requests one more record than the supplied fixed-width
body contains. With four native tasks already admitted, the producer detects
truncation; the test releases gated workers *from the admission error hook*
and confirms that all four complete, ordered batches are returned before the
terminal truncation error. This distinguishes a producer read-ahead error
from a decode error in an earlier logical task.

## Cancellation and lifetime checkpoints

- Cancel a native fixed-width task at the 4096-record checkpoint, join it,
  cancel its unpublished pool slot, and reacquire storage.
- Cancel a native big-endian variable-list task at the 4096-item checkpoint
  and do the same; partially written list columns must not be published.
- Destroy a parser with three native tasks deliberately paused in decoding,
  in both ordered and unordered modes. `cancelPending` signals every future,
  invokes a test-only `after_cancel_signal` callback to release the atomic
  gate, then joins the futures **before** freeing task and output storage.
  The test allocator diagnoses leaks.

The new hooks are internal and only run under Zig's test build. Existing
Phase 7/9 tests continue to cover ASCII list cancellation and completion
notification failures, while M12 covers reader/allocation interruptions.

## Boundaries and outstanding work

The scheduler's completion sequence is controlled deterministically; OS
thread execution itself is not replaced with a virtual executor. These tests
do not claim that cancellation is externally exposed at every individual
internal allocation or producer checkpoint. In particular, the parser API
currently has no independent public cancellation token; `deinit` and native
future cancellation are the tested shutdown mechanisms. Runtime verification
under the project's Zig 0.17.1 toolchain remains required before closing M13.
