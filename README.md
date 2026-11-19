# zply

`zply` is a streaming PLY 1.0 parser for Zig 0.17's `std.Io` API. It decodes
ASCII, binary little-endian, and binary big-endian PLY data into typed,
columnar batches without requiring a seekable source or materializing the
whole file.

The public module name is `zply`:

```zig
const zply = @import("zply");
```

## Features

- PLY 1.0 ASCII, binary little-endian, and binary big-endian input.
- All eight canonical scalar types and arbitrary scalar/list property layouts.
- Typed scalar columns and list offset/value columns.
- Caller-owned `std.Io.Reader`, allocator, and I/O implementation.
- Bounded parser-managed allocation through `Options.memory_budget`.
- Ordered delivery by default, with completion-order delivery when requested.
- Native `std.Io` concurrent decoding when the supplied backend supports it;
  sequential fallback otherwise.
- Structured diagnostics, adversarial regression coverage, fuzz targets, and
  reproducible Phase 12 benchmark tooling.

`zply` parses structure and values. It does not infer geometry semantics,
triangulate polygons, validate mesh topology, transform coordinates, or write
PLY files.

## Quick start

The examples use a fixed reader to be self-contained. In an application,
replace it with the caller-owned reader for a file, socket, pipe, or other
stream.

```zig
const std = @import("std");
const zply = @import("zply");

var threaded: std.Io.Threaded = .init_single_threaded;
var reader: std.Io.Reader = .fixed(ply_bytes);
var parser = try zply.Parser.init(allocator, threaded.io(), &reader, .{});
defer parser.deinit();

const header = parser.header(); // valid until parser.deinit()

while (try parser.next()) |batch_value| {
    var batch = batch_value;
    defer batch.release();

    // Property indexes are declared-schema indexes.
    const x: []const f32 = try batch.typedColumn(f32, 0);
    _ = x;
}
```

Every returned `Batch` is one lease on parser-owned storage. Release it before
destroying the parser; copying a `Batch` does not create another lease. The
parser never closes, seeks, resets, or otherwise takes ownership of the
reader, its source, the allocator, or the supplied I/O implementation.

## Consuming from a Zig build

For local development, add a path dependency named `zply` in the consuming
project's `build.zig.zon`, then attach the dependency module:

```zig
const zply_dep = b.dependency("zply", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("zply", zply_dep.module("zply"));
```

The repository's [standalone consumer](tests/consumer/) is the executable
smoke test for this integration. A versioned archive installation command will
be documented with the first published release; do not substitute an
unversioned repository URL for a content-hashed release dependency.

## Format support

| Feature | ASCII | Binary LE | Binary BE |
| --- | --- | --- | --- |
| PLY 1.0 header | Yes | Yes | Yes |
| Canonical scalar properties | Yes | Yes | Yes |
| Variable-length list properties | Yes | Yes | Yes |
| Mixed scalar/list schemas | Yes | Yes | Yes |
| Multiple and zero-count elements | Yes | Yes | Yes |
| Non-seekable streams | Yes | Yes | Yes |
| Native concurrent decoding | Backend-dependent | Backend-dependent | Backend-dependent |

The parser is strict by default. `Options.strict = false` enables the
documented scalar-type aliases and duplicate-name compatibility behavior; it
does not promise support for arbitrary nonstandard PLY extensions. PLY versions
other than 1.0 and noncanonical scalar extensions are rejected.

## Memory and execution

`memory_budget` limits accounted parser-owned capacity, including metadata,
raw chunks, decoded columns, list offsets, task bookkeeping, staged records,
and reservations. It does not cap process RSS, reader buffers, executor
allocations, thread stacks, allocator overhead, or application memory.

The parser may return recoverable resource-pressure errors when consumer-held
batches prevent progress. Release the relevant batches before retrying.
Malformed input, truncation, and ordinary reader failures are terminal for the
parser. See [the lifecycle contracts](docs/performance/phase13_m2_lifecycle_contracts.md)
and [the options/error review](docs/performance/phase13_m3_options_errors_diagnostics.md)
for the exact contracts.

The parser finds independent chunks; the supplied `std.Io` implementation
decides whether they execute concurrently. There is no parser worker-count or
thread-count option. `preserve_order = false` permits completion-order
delivery, but applications must use `BatchInfo.first_record` and `sequence`
rather than assume arrival order.

## Examples and validation

```sh
zig build test-examples                 # compile and execute public examples
zig build test-consumer                 # run a separate local-path consumer
zig build test -Doptimize=ReleaseSafe   # complete functional suite + both gates
zig build bench-phase12 -Doptimize=ReleaseFast -- --help
zig build install-bench -Doptimize=ReleaseFast
```

The examples cover header inspection, record counting, typed XYZ bounds, list
columns, memory accounting, unordered batch metadata, and diagnostics. They
are compiled and run by `test-examples`.

Phase 12 uses a deterministic warm-memory benchmark harness with separate
body and lifecycle timing, raw measurements, validation/minimal consumers,
and comparable CSV reports. See [the benchmark audit](docs/performance/m1-benchmark-audit.md),
[baseline capture procedure](docs/performance/m4-baseline-capture.md), and
[profiling workflow](docs/performance/m5-m6-instrumentation-profiling.md).

## Development status

The implementation contains the parsing, memory, concurrency, diagnostics,
and Phase 12 measurement foundation described by the roadmap. Phase 13
packaging is in progress: the package/module boundary, examples, and local
standalone consumer are now validated; release-archive verification, public
API documentation generation, release policy files, and publication remain
before a tagged public release.

## License

MIT — see [LICENSE](LICENSE).
