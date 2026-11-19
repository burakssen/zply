# Phase 11 M12 — Deterministic Reader and Allocation Faults

This milestone extends existing init-failure, variable-list staged-retry,
completion-queue, and native in-flight allocation tests with **one reusable
non-seekable reader** and end-to-end fault matrices.

## Reader model

`tests/fault_reader.zig` uses `std.Io.Reader.VTable.stream`; it has no seek or
reopen operation. A repeating fragment pattern limits bytes delivered on each
underlying read. `cutoff` optionally replaces further delivery with either
`error.ReadFailed` or `error.EndOfStream`. The reader records both successful
underlying bytes (`position`) and attempts (`calls`). These are not guaranteed
to equal the parser's logical consumed offset when the caller's Reader has
prefetched data.

The M12 tests exercise:

* ASCII, binary little-endian, binary big-endian.
* Short and irregular reads, including splits inside a numeric token, a
  two-byte list count, a list payload, and the final record.
* Header failures with `initDetailed()` diagnostic snapshots.
* Body failures with `lastDiagnostic()`; completed batches may precede an
  error, but no partial batch may be published.
* EOF/truncation versus underlying `ReadFailed` category separation.
* A failure sentinel immediately **after** the declared body to detect
  speculative reads that would prevent successful completion.
* Trailing bytes remaining available to the caller.

## Allocator model

The existing Zig `std.testing.FailingAllocator` is injected at each early
initialization allocation, then at each of 90 offsets after successful
initialization for each encoding. Tests check exact batch contents if parsing
continues, bounded memory and cleared reservations, and byte-exact leak
accounting after parser destruction.

Failures during some stages can leave a parser in its documented terminal
`.failed` state; M12 does **not** assume every OOM is retryable. Clearing a
one-shot allocator failure permits retry **only if** the parser remains live.

Earlier tests cover deeper staged binary-list OOM and native in-flight task
failures (`binary_variable_recovery_test.zig`, `fault_injection_test.zig`). M12
must not suppress or replace them.

## Running

```sh
zig build test
zig build test -Doptimize=ReleaseSafe
zig build test -Doptimize=ReleaseFast
zig build test-faults
```

No public API or production code is changed. Tests use only the `zply_internals`
module universe, avoiding duplicate source ownership in Zig 0.17.1.
