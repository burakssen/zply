# Phase 11 M14 — Batch ownership and memory verification

## Scope

The public parser and its Zig 0.17.1 `std.Io` execution path remain unchanged.
M14 extends the deterministic hardening suite with tests using a separately
instrumented backing allocator. All allocations that `zply` requests from this
allocator are counted independently of its own memory budget controller.

## Required invariants

- **Owner lifetime:** a `Batch` is one lease. Copying the handle does not
  acquire a second lease. Calling `tryRelease` on a stale copy returns
  `error.InvalidBatchLease`; `release` and data access panic on invalid use.
  The parser and its pool must still exist before calling `isValid` or any
  other method on the handle.
- **Generation:** after release and pool-slot reuse, the generation changes;
  old copies must never become valid again. Growth of the pool's slot table
  cannot invalidate live leases because handles use stable pool identity and
  slot indices; decoded buffers are separate allocations.
- **Retained data:** list offsets, list values, and scalar columns stay stable
  while other batches are admitted and element schemas change.
- **Accounting:** at safe synchronous checkpoints,
  `backing_live_bytes == parser.memoryStats().live_bytes`. The backing
  allocator's measured peak never exceeds the parser's reserved+live peak.
  Tracked capacity includes retained and leased allocations, not only their
  initialized payload lengths.
- **Budget:** `live + reserved <= budget` and `peak_total <= budget` at all
  sampled checkpoints. Returning a batch lease to the pool does **not**
  implicitly free its backing allocation: the bytes remain live and become
  reusable or reclaimable cached storage.
- **Pressure:** a held consumer lease can cause `MemoryPressure`. Releasing
  that lease permits retrying the same staged list record without dropping or
  duplicating it.
- **Destruction:** release consumer leases before parser deinitialization.
  A successful `deinit` releases all parser-owned bytes. The caller owns the
  borrowed Reader, the I/O executor and the backing allocator.

## Coverage

`tests/phase11_ownership_memory_test.zig` verifies:

1. Twelve simultaneously retained one-record batches, pool growth, stale
   copies and subsequent generation-checked slot reuse.
2. Binary-list offset/data stability across an element transition with three
   simultaneous consumer leases.
3. All three encodings against 32 KiB, 128 KiB and 1 MiB budgets, comparing
   independent backing-allocator capacity and parser counters after every
   emitted batch.
4. Exclusive reservations, refusal of allocations that would steal reserved
   capacity, and safe coexistence of old and replacement allocations.
5. ASCII-list staged-record recovery from `MemoryPressure` under a budget
   derived from measured one-lease and two-lease footprints.

Existing `lease_panic_probe.zig` child-process checks cover three deliberately
invalid operations (stale release, stale access, active lease at parser
shutdown). The M14 tests check recoverable `tryRelease` without a panic.

## Commands

```sh
zig build test-ownership-memory
zig build test
zig build test -Doptimize=ReleaseSafe
zig build test -Doptimize=ReleaseFast
```

The project does not depend on an additional worker setting or change its
public `Parser.init`/`next`/`Batch.release` contract.
