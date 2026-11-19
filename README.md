# zply

A high-performance streaming parser for the [PLY (Polygon File
Format)](https://paulbourke.net/dataformats/ply/), written in Zig 0.17
against the native `std.Io` abstractions.

**Status: Phase 7 concurrency implementation — compile and runtime validation pending.**
`Parser.init` parses and validates headers over a borrowed reader, compiles
record layouts, and retains parser-owned metadata. `Parser.next()` streams
fixed-width binary records into leased typed columns. Decode chunks of at
least 64 KiB request concurrency through the caller's `std.Io`; the parser
falls back to inline decoding when concurrency is unavailable. Ordered
results preserve original sequence, while unordered results are discovered
through a bounded `std.Io.Queue`.

This source revision has not been compiled in the review environment because
Zig 0.17 was unavailable. Run the full test and benchmark commands below
before treating the concurrency path as validated.

## Design principles

- **Reader-first.** The parser borrows any `std.Io.Reader` — a fixed memory
  buffer (`std.Io.Reader.fixed`), a file, a socket, or a mid-stream slice of
  a larger document — and never owns, closes, seeks, or resets it.
- **No global state.** One parser instance, one allocator, no hidden globals,
  no custom thread pool.
- **Schema-generic.** Elements and properties are arbitrary; names such as
  `x`, `y`, `z`, `red`, or `vertex_indices` are conventions, never hardcoded.
- **Explicit ownership.** Every allocation is documented and owned by the
  parser until `deinit`.

## Usage (functional from Phase 2 onward)

```zig
const ply = @import("ply");

var reader: std.Io.Reader = .fixed(ply_bytes);

var parser = try ply.Parser.init(
    allocator,
    io,          // any std.Io implementation, e.g. threaded.io()
    &reader,
    .{},         // default Options
);
defer parser.deinit();

const header = parser.header();
for (header.elements) |element| {
    // element.name, element.count, element.properties
}
for (parser.layouts()) |layout| {
    // compiled record layout: fixed offsets/widths, body offsets
}

while (try parser.next()) |value| {
    var batch = value;
    defer batch.release();
    // Inspect batch.info() and batch.columnByPropertyIndex(...).
}
```

`Parser.init` validates the configuration, then parses the header over the
borrowed reader: bounded line reading (LF and CRLF, per-line and total byte
limits), strict directive grammar, and record-layout compilation. On success
the reader is positioned at the first body byte; `header()` and `layouts()`
return parser-owned metadata without touching the reader. Release every batch
before destroying the parser. The pool may grow its bookkeeping to accommodate retained batch leases,
subject to the global parser-managed memory budget. When capacity cannot be
admitted, release retained batches before retrying.

## Public API

| Type          | Purpose                                                        |
|---------------|----------------------------------------------------------------|
| `Parser`      | Streaming parser lifecycle (`init`/`header`/`next`/`deinit`)   |
| `Batch`       | One batch of decoded records from `Parser.next`                |
| `BatchInfo`   | Element, record range, and sequence for a batch                |
| `Column`      | Property index and read-only typed values                      |
| `ScalarColumn` | Tagged read-only slices of the eight scalar types             |
| `RecordView`  | Borrowed, on-demand view of one decoded record (via `decode`)  |
| `Options`     | `memory_budget`, `chunk_size`, `preserve_order`, `strict`      |
| `Limits`      | Defensive caps on header size, element counts, record size     |
| `Header`      | Encoding, version, elements, comments, `obj_info`, body offset |
| `Element`     | Name, declared record count, ordered properties                |
| `Property`    | Scalar value or (count type, item type) list                   |
| `ScalarType`  | The eight canonical PLY 1.0 scalars (`char`…`double`)          |
| `IntegerType` | Integer-only subset used for list counts                       |
| `Encoding`    | `ascii`, `binary_little_endian`, `binary_big_endian`           |
| `PropertyLayout` | Compiled property offsets/widths/types within a record      |
| `ElementLayout`  | Compiled record/body sizes and body start offsets           |
| `ScalarValue`    | Typed decoded scalar (tagged union over the 8 PLY types)    |
| `decode`         | Pure binary decode engine: scalars, records, ranges         |
| `Error`       | Documented union of every parser error, introduced per phase   |

The API is independent of the filesystem, of OS handles, of the concurrency
implementation, and of point-cloud semantics. There is no `openFile`,
`setWorkers`, `startThreadPool`, or `seekToRecord`.

## Sequential binary streaming (Phase 4)

The internal producer reads one element at a time in complete-record chunks.
It reuses a lazily allocated raw buffer, supports zero-width records without
reading, rejects ASCII and nonempty list elements, and detects truncated
bodies. Completion is based on declared record counts; trailing bytes remain
available to the caller's reader. A chunk borrows its buffer until the next
read. `Parser.next()` decodes into parser-owned column buffers before
publishing a lease; it never overwrites a leased batch.

The memory budget currently accounts allocator-requested parser capacity,
including header metadata, raw input, pool buffers, and the control object.
It excludes caller-owned memory, allocator overhead, and process RSS.
The parser halves a preferred chunk until its raw and column growth fits the
budget, then reserves that growth together before reading it. Available pool
slots with incompatible schemas may be evicted; leased slots are never
reclaimed. If even one record cannot fit, `ResourceLimitExceeded` is returned
without advancing the reader.

`parser.memoryStats()` returns a consistent snapshot containing current and
peak accounted bytes plus diagnostic counters for batch-size reductions, pool
evictions, reclaimed bytes, and reservation failures. These values describe
allocator-requested parser capacity, not allocator-internal overhead or RSS.
The snapshot also reports raw-buffer capacity, decoded-column capacity, and
retained versus leased pool capacity; these breakdown fields are diagnostic
subsets of `live_bytes`, not additional charges.

Run the warm-memory streaming baseline with
`zig build bench-streaming -Doptimize=ReleaseFast`. It reports producer and
integrated decoding throughput across six chunk sizes for 3M XYZ f32 records;
it is not a cold-storage benchmark.

## Concurrent decoding (Phase 7)

The producer remains the only reader owner. It reserves and reads complete
fixed-width chunks sequentially and can overlap a new read with the decoding
of an earlier chunk. Up to two chunk tasks may be outstanding at once (an
internal bounded scheduling limit, **not** a worker or thread count).
Tasks keep stable, generation-checked descriptors and distinct raw buffers;
workers write only to independently owned column allocations. The caller's
`std.Io` implementation controls actual execution parallelism.

Ordered output joins the lowest outstanding sequence first. Unordered output
consumes task completion identifiers from an `std.Io.Queue` sized to hold
all outstanding notifications, then joins the matching native future.
Failures stop new admission; completed ordered-prefix batches can be returned
before a deferred producer error. Shutdown requests cooperative cancellation
and joins all futures before destroying buffers. Tasks check an atomic stop
flag after at most 4096 decoded records.

Memory is charged for parser-owned task descriptors, queue backing, raw and
decoded buffers, and pending reservations. Allocations internal to the
supplied `std.Io` executor are outside the parser-managed budget. The
parser can read ahead beyond the last returned batch, and cannot rewind a
non-seekable reader after a failure.

`parser.executionStats()` distinguishes admitted tasks, native submissions,
submission rejections, inline decodes, peak admitted tasks, and peak actual
simultaneously running decode operations.

```sh
zig build test
zig build test -Doptimize=ReleaseSafe
zig build bench-concurrent -Doptimize=ReleaseFast
```

Benchmark outputs include native accepted/rejected submission counts and
active decode concurrency. Full throughput, race and scheduling regression
validation is still necessary on a local Zig 0.17 toolchain.

## Typed batch ownership (Phase 5)

Each `Batch` is a lease on pool-owned storage. Columns stay stable across
subsequent `next()` calls until that lease is released. Do not treat a copied
handle as another lease; accessing or releasing a stale handle is invalid.
`tryRelease()` reports `error.InvalidBatchLease` for a stale handle while the
pool is alive, and `release()` panics on the same violation. All batches must
be released before `Parser.deinit()`; using any handle after deinitialization
is invalid.

Column views are read-only and contain exactly `batch.info().record_count`
values. For a known `f64` property at index 0:

```zig
const x: []const f64 = try batch.f64Column(0);
// Other scalar types use batch.typedColumn(T, property_index).
```

`zig build bench-columns -Doptimize=ReleaseFast` compares generic record
decoding, record-major and property-major direct column decoding, and
`Parser.next()`, using seven schemas in both byte orders. Each timed path
includes the same record-order checksum traversal. Output allocations for
the standalone direct decoders occur before timing; `next` includes its
initial allocations. On the development machine, a sample 200,000-record
warm-memory run measured XYZ f32 little-endian at about 8.6 ns/record
for generic records, 10.9 ns/record for record-major columns, and 7.9
ns/record for property-major columns. These figures are machine-specific and
not cold-storage throughput.

## Binary decoding (Phase 3)

The decoder is a pure, allocation-free engine separate from the parser: it
receives a compiled `ElementLayout` and a borrowed byte slice and produces
typed values, without knowing where the bytes came from. It performs no I/O,
never allocates, and holds no shared mutable state, so the same primitives
power sequential, batched, projected, and (later) concurrent decoding.

```zig
const ply = @import("ply");

// Validate the compiled layout once, bound to a byte order.
const fixed = try ply.decode.FixedLayout.initForEncoding(&layout, .binary_little_endian);

// Decode one record into caller-owned storage.
var values: [6]ply.ScalarValue = undefined;
try ply.decode.decodeRecord(fixed, record_bytes, &values);

// Or traverse a whole range, decoding per property on demand.
const Sum = struct { bits: u64 = 0,
    fn consume(self: *@This(), _: u64, view: ply.decode.RecordView) !void {
        self.bits ^= (try view.get(0)).bits(); // projected access
    } };
var sum = Sum{};
try ply.decode.decodeRange(fixed, body_bytes, record_count, &sum, Sum.consume);
```

Key properties:

- **Declared types are preserved.** `property uchar red` stays `u8`,
  `property double x` stays `f64`; `ScalarValue` is a tagged union over the
  eight canonical types, never an `f64` conversion.
- **Bit-exact floats.** Decoding reinterprets integer bit patterns
  (`@bitCast`, never `@floatFromInt`), so NaN payloads, infinities,
  subnormals, and negative zero pass through exactly.
- **Packed records.** Scalars decode from arbitrary (unaligned) byte
  offsets; mixed-width properties need no padding.
- **Checked arithmetic.** Every length, offset, count, and index is
  validated before memory access; errors are controlled, never panics.
- **Variable-length rejection.** Elements containing list properties are
  rejected by the fixed-width APIs (`VariableLengthElement`) rather than
  guessed at.

Decode errors (`ply.decode.DecodeError`): `InsufficientBytes`,
`InvalidRecordLength`, `InvalidPropertyIndex`, `InvalidOutputLength`,
`VariableLengthElement`, `UnsupportedEncoding`, `InvalidLayout`,
`SizeOverflow`. Every bit pattern of every canonical scalar type is a valid
value — there is no "invalid float" error.

## Ownership contract

| Resource                       | Owner   | Lifetime                                  |
|--------------------------------|---------|-------------------------------------------|
| Allocator implementation       | Caller  | Must outlive the parser                   |
| `std.Io` implementation        | Caller  | Must outlive the parser and active calls  |
| `std.Io.Reader`                | Caller  | Must outlive the parser                   |
| Underlying file/socket/memory  | Caller  | Must remain readable while parsing        |
| Parsed header                  | Parser  | Until `deinit`                            |
| Property/element names         | Parser  | Until `deinit`                            |
| Decoded batch storage          | Parser pool      | Until parser deinitialization    |

Reader invariants: the parser advances the caller's reader from its current
logical position (mid-stream readers are supported and
`Header.body_offset` is relative to that position), never assumes seeking,
never touches the buffer, and never reads on destruction — trailing
non-PLY data in the stream stays untouched.

Initialization is **not transactional with respect to the reader**: if a
malformed header is detected after several valid lines, the reader has
already advanced past them. The parser frees all of its allocations on
failure and never attempts to rewind the caller's reader; a failed `init`
requires no `deinit`.

## Parser lifecycle

```
initializing ──▶ ready ──▶ reading ──▶ completed
     │              │          │
     └──────────────┴──────────┴──────▶ failed      (terminal)
any state ─────────────────────────▶ destroyed    (via deinit)
```

- `init` validates options, binds borrowed resources, and parses and
  validates the header (bounded line reading, directive grammar, layout
  compilation). A failed `init` cleans up its allocations; the caller must
  not call `deinit` on a failed result.
- `next() == null` means *all declared records were successfully consumed*,
  never an I/O failure.

## Error handling

Every operation exposes a narrow error set. Categories and the phase that
introduces them:

| Category                          | Introduced in |
|-----------------------------------|---------------|
| Invalid configuration             | Phase 1       |
| Out of memory                     | Phase 1       |
| Invalid magic/format/directive    | Phase 2       |
| Unsupported encoding/version      | Phase 2       |
| Unsupported scalar type           | Phase 2       |
| Invalid element/property          | Phase 2       |
| Invalid line ending               | Phase 2       |
| Numeric overflow                  | Phase 2       |
| Invalid binary record             | Phase 3       |
| Truncated input                   | Phase 4       |
| Resource limit exceeded           | Phase 4       |
| Concurrent execution failure      | Phase 7       |

`Diagnostic` defines the shape for located errors: category, the header
line number and directive, optional element/property/record indices, and an
optional byte offset relative to the parser's start position — all `u64`,
sized for billions of records.

Header parsing details (compatibility mode differences live under
`Options.strict`):

- Keywords are case-sensitive; blank lines are skipped; every header line
  must be newline-terminated (LF or CRLF).
- `comment`/`obj_info` payloads are free text: one separator after the
  keyword is excluded, interior spacing is preserved, and they never reset
  the active element.
- Element record counts parse as exact decimal integers (`u64`), never as
  floats; no record storage is allocated from them.
- Strict mode rejects duplicate element/property names and non-ASCII
  structural names; compatibility mode keeps duplicate declarations as
  separate schema entries and accepts case-insensitive scalar spellings
  plus the `float32`/`float64` aliases.

## Building and testing

Requires Zig 0.17.0 or later.

```sh
zig build                            # compile the library
zig build test                       # run unit and integration tests
zig build test -Doptimize=ReleaseFast
zig build -Doptimize=ReleaseFast     # optimized build
zig build bench -Doptimize=ReleaseFast  # in-memory decode benchmarks
zig fmt --check src tests build.zig  # formatting check
```

Downstream packages depend on this module under any name, e.g.:

```zig
// consumer build.zig
const zply_dep = b.dependency("zply", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("ply", zply_dep.module("zply"));
```

Internal units (the bounded line reader, the header parser/builder, and the
layout compiler) are exposed to the library's own test suites through an
`zply_internals` module that is not part of the public API surface.

## Roadmap

| Phase | Scope                                                     | Status   |
|-------|-----------------------------------------------------------|----------|
| 1     | Types, configuration, lifecycle scaffolding               | done     |
| 2     | Header parsing, validation, and layout compilation        | done     |
| 3     | Binary record decoding (little/big endian)                | done     |
| 4     | Sequential fixed-width binary streaming                  | done     |
| 5     | Decoded batches and column storage                        | done     |
| 6     | Global memory budget and adaptive admission               | implemented |
| 7     | Concurrent execution on top of the supplied `std.Io`      | planned  |

## License

MIT — see [LICENSE](LICENSE).

## Phase 8 ASCII PLY

Sequential ASCII records (scalars and typed lists) are now supported via the
same `Parser.next()` API used by binary input. Use
`batch.listColumn(property_index)` for list data; see
[Phase 8 implementation details](docs/phase8-implementation.md) for strict
line grammar, memory behavior and benchmarks.


### Phase 9: native concurrent ASCII decoding

Large ASCII PLY streams now use record-aligned, budgeted chunks with parallel
scalar and list decoding through the caller's `std.Io` implementation.
`Parser.init(allocator, io, reader, options)` and `Parser.next()` are unchanged;
there is no parser worker-count setting. See `docs/phase9-implementation.md`.

Run `zig build bench-ascii-concurrent -Doptimize=ReleaseFast` to compare the
single-context fallback with threaded ordered and unordered delivery.
