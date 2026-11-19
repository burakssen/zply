# Phase 9 — Concurrent ASCII PLY decoding

This implementation adds record-aligned concurrent ASCII decoding using the
caller's `std.Io`. **No worker count, custom threads, or alternate public parser
entry point** is introduced.

## Execution path

1. The single coordinator reads complete LF/CRLF lines through the existing
   `std.Io.Reader`, bounded Phase 8 record scratch, and Phase 9 chunk builder.
2. Each chunk contains exactly one element, original source bytes and a
   monotone `record_count + 1` boundary index.
3. Scalar-only chunks require no numeric preflight. List-bearing chunks use
   structural preflight to calculate exact list-value capacity without parsing
   all numeric values twice.
4. All decoded storage is acquired before task submission, using the existing
   global accounting allocator and batch pool. Native tasks never allocate,
   access the reader, or mutate another task's columns.
5. The Phase 7 registry, native `std.Io.concurrent`, inline fallback,
   and generation-checked leases handle delivery and lifetime. Ordered tasks
   are joined directly in sequence order; unordered tasks publish through the
   bounded completion queue. Ordered tasks never enqueue unused notifications,
   which could otherwise fill the queue and block future completion.
6. If a staged chunk is too large to admit, the coordinator tries a smaller
   complete-record prefix. The original staged bytes remain available until
   an independent task owns an immutable prefix copy.
7. On task completion, raw bytes and boundaries are reclaimed independently
   from the returned batch lease. `Parser.deinit` cancels and joins tasks.

Small ASCII files and configurations with `chunk_size < 64 KiB` retain the
Phase 8 sequential path, which avoids scheduling overhead for small fixtures
and preserves its existing single-record list batch behavior.

## Resource guarantees

- The caller-owned input reader is only advanced by the coordinator.
- Builder scratch, raw chunks, boundary arrays, preflight arrays, task slots,
  column allocations and leases use the Phase 6 global memory budget.
- A pending complete record or chunk is retained when output memory cannot
  currently be admitted. Releasing consumer batches can permit progress.
- The native `std.Io` implementation decides if work truly executes in
  parallel. `ConcurrencyUnavailable` falls back to inline decoding.
- The parser never needs seeking or rewinding. A budget denial while
  growing the line scratch can occur *mid-record*: the reader keeps the
  partial bytes and the not-yet-appended byte, then resumes that same record
  when memory is available. Previously staged complete records can be
  dispatched before retrying the partial record.
- When an earlier batch lease prevents that scratch allocation, the parser
  returns recoverable `MemoryPressure` rather than declaring the source
  malformed or discarding already consumed bytes.
- Reader failures discovered while filling a chunk preserve earlier valid
  staged records for delivery before reporting the terminal error.

The first version keeps byte staging and task-input buffers separate. This
incurs a bounded copy, but avoids shared-buffer lifetime and reference-count
complexity during splitting. Pool reservations are enforced at allocation
through the same global accounting allocator, rather than pre-reserving an
entire variable-length chunk with `ReservedAllocator`.

## Validation

```sh
zig build test
zig build test -Doptimize=ReleaseSafe
zig build test-ascii-large -Doptimize=ReleaseFast
zig build bench-ascii-concurrent -Doptimize=ReleaseFast
zig build bench-concurrent -Doptimize=ReleaseFast
```

The concurrent ASCII tests cover ordered and unordered scalar and list
records, inline fallback, split LF/CRLF boundaries, malformed worker input,
multiple elements, zero-property records and preservation of trailing input.

The benchmark separately reports single-context and threaded execution for
XYZ and list-bearing data, with records/s, source throughput, allocation peak
and native task statistics. Execution capacity is configured by the caller's
`std.Io`, never by the parser.

## Remaining performance work

The sequential producer currently copies each complete record into staged
chunk storage; on task admission it copies an immutable prefix for decoding.
This is correctness-first and can become a bottleneck. Profile boundary
scanning, text conversion, preflight and scheduling separately before
introducing vectorized newline scanning or shared staging buffers.

### Retained-batch pressure and cached output slots

ASCII admission may need to allocate raw record copies and their boundary
indices before the batch-pool's schema-specific reclamation runs. A batch
whose lease was released is *available*, but its decoded allocation stays
cached, and can block this earlier raw admission under a tight budget.
On budget-pressure errors, the producer now makes a bounded retry after
reclaiming **only available** pool slots. Filling, ready, and leased slots
are never evicted, and staged input (including a partial line and any
pending byte) is preserved. Idle reclamation is not performed on the normal
hot path; each retry must reclaim actual bytes to prevent retry loops.
