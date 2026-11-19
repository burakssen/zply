# Phase 11 M2 — Diagnostic snapshots

## Public API (additive)

- `Parser.init(allocator, io, reader, options)` remains unchanged.
- `Parser.initDetailed(allocator, io, reader, options, &diagnostic)` optionally provides a header/configuration error snapshot, even if no parser object was created.
- `Parser.lastDiagnostic()` returns `?Diagnostic` by value after a failed `next()` call. A successful `next()` call clears this unified snapshot.
- `Parser.asciiDiagnostic()` and `Parser.binaryDiagnostic()` remain available for compatibility.

`Diagnostic.code` is the **exact Zig error value** returned to the caller (as `?anyerror`), not a formatted string or an allocation. `code == null` means no failure for a successful `initDetailed` call. `stage` distinguishes configuration, header, schema, input, preflight, decode, scheduling and memory. `category` remains the existing coarse classification. Source fields are optional: callers must not assume the element, record or property is available for every failure.

All indexes are zero-based except header/ASCII line numbers, which are one-based. Document-relative `byte_offset` is the beginning of the failing record or header line where known; `failure_byte_offset` is the header-reader's consumed cursor at the time of failure. The caller's reader may have prefetched beyond this logical position. No operation attempts a rewind.

## Limitations and following milestones

- Header error locations are recorded after bounded line reads; a header line that fails before returning its contents records the attempted line start and the consumed byte cursor. Column-level header token offsets are not yet tracked.
- The unified streaming accessor records the exact returned error for any `next()` failure, including those lacking a format-specific location. Existing ASCII/binary source context is reused only if its error matches that returned error.
- This milestone does **not** establish deterministic error precedence for multiple concurrent failures, full `expected`/`actual` population, or a complete strict/compatibility acceptance matrix; those are separate Phase 11 milestones.
- Consumers must release batches before parser destruction; retaining a Diagnostic snapshot does not retain a batch or input allocation.

Validation: `zig build test`, `zig build test -Doptimize=ReleaseSafe`, plus the existing large-stream and fuzz targets. The diagnostic interface itself requires no heap allocations.
