# Parser allocation audit (Phase 6)

This inventory covers allocator-visible capacities. The parser now creates a
stable budget controller before header parsing and routes parser-owned
allocations through it. Allocation requests and their transient replacement
peaks are charged; this does not include allocator-internal overhead or RSS.
`Parser.next()` reserves its estimated raw and column growth together before
preparing either buffer. Adaptive admission and reclamation remain in progress.

| Allocation | Owner | Capacity to charge | Release |
| --- | --- | --- | --- |
| Header arena backing blocks | `HeaderStorage.arena_state` | Each backing allocation, including spare arena capacity | `HeaderStorage.deinit` |
| Header line scratch | `HeaderLineReader` | Allocator-visible scratch capacity | `HeaderLineReader.deinit` on init success or failure |
| Builder elements, properties, names, comments, layouts | Header arena | Included in arena backing blocks; do not count individual objects again | With arena |
| Raw chunk buffer | `Parser.raw_buffer` | Full allocated byte slice, even when a chunk is shorter | `RawBuffer.deinit`, or future reclamation |
| Pool object and embedded slots | `BatchPool` | Full pool object allocation | `Pool.destroy` |
| Column descriptors and owned-column arrays | Individual pool slots | Full allocated descriptor arrays | Slot replacement or pool destruction |
| Typed column arrays | Individual pool slots | Capacity in values times scalar width | Slot replacement or pool destruction |
| Batch lease | Consumer handle, pool-owned backing | No allocation for the handle itself; underlying pool slot remains charged while leased | `Batch.release` changes state only |
| Budget and allocator control object | Parser | Bootstrap object size, charged immediately after allocation | After other parser-owned allocations are freed |
| Producer and parser fields | Parser value | No separate heap allocation | Parser lifetime |
| Reader, its buffer and source; `std.Io`; consumer data | Caller | Excluded | Caller |

The batch planner now halves a preferred candidate when its accounted growth
does not fit. The pool object itself is created and charged before estimating
and reserving per-chunk raw and column growth. Available incompatible slots
are reclaimed before admission; leased slots remain charged and untouched.
`MemoryStats` exposes reduction count, eviction count, reclaimed bytes, and
reservation-failure count for observing this behavior.

The batch pool starts small and grows its slot table on demand. Slot-table
growth itself is allocated through the budget-aware allocator, so retaining
more batches consumes accounted capacity and can fail before the reader is
advanced.
