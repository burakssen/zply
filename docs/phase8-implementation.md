# Phase 8 — sequential ASCII PLY decoding

Phase 8 adds strict one-line-per-record ASCII PLY support through the existing
`Parser.init(allocator, io, reader, options)` / `Parser.next()` API. The reader
remains caller-owned, is never rewound or closed, and is not accessed by any
decode worker. Phase 7's binary pipeline is unchanged at the parser dispatch.

## Grammar and limits

- Exactly one ASCII line per declared record, including zero-property records.
- LF and CRLF record terminators are accepted; a final unterminated line is
  rejected. Blank lines count as empty records and are valid only when the
  element has no properties.
- Values are separated by spaces or tabs. Missing/extra values, bad numeric
  text, NUL/control bytes, invalid line endings, and count mismatches fail.
- Integer tokens use decimal syntax and checked signed/unsigned ranges.
- Floating point uses correctly typed `std.fmt.parseFloat` conversion; `nan`,
  `inf`, `+inf`, `-inf` are accepted explicitly, while decimal overflow and
  noncanonical spellings are rejected. Signed zero is preserved.
- `Limits.max_ascii_record_bytes` (8 MiB), `max_ascii_token_bytes` (4 KiB),
  and `max_list_items_per_record` (1,000,000) constrain body input.
- A PLY list property is exposed through `batch.listColumn(property_index)`;
  it has monotonically increasing offsets and one contiguous typed values
  column. Scalar API `batch.typedColumn(T, property_index)` is unchanged.

## Streaming and memory

Scalar records are decoded into reusable typed column batches, with output
admitted before the reader consumes the next line. For variable-length list
records, the parser stages one complete line before allocating list output,
because the item count is unknown until the count token is read. This staging
is accounted within the global Phase 6 allocator budget and is retained across
`error.MemoryPressure` if consumer-held batches are the reason admission
cannot proceed. The same line is retried before reading another record.

List-containing elements currently emit **one record per batch** to keep
memory-pressure recovery atomic; this is correct but may increase overhead for
face-heavy meshes. A future optimization can coalesce several list records
without changing the list-column representation or public API.

A shortage caused by permanently inadequate parser memory is a terminal
`ResourceLimitExceeded`; `MemoryPressure` is recoverable when releasing a
consumer lease permits progress. If memory is exhausted during the middle of
reading a scalar line, the parser fails terminally rather than pretending the
reader can be rewound. All successfully published leases stay valid until
released and must be released before parser destruction.

`Parser.asciiDiagnostic()` describes the element, record, property (when
known), body-relative byte offset translated into parser-relative coordinates,
and physical body line of a terminal ASCII decoding error. For token-level
validation errors, `token_byte_offset` independently identifies the start of
the invalid token (or the record end for a missing value); `byte_offset`
continues to identify the record start.

## Run

```sh
zig build test
zig build test -Doptimize=ReleaseSafe
zig build bench-ascii -Doptimize=ReleaseFast
zig build bench-ascii-numbers -Doptimize=ReleaseFast
zig build bench-concurrent -Doptimize=ReleaseFast
```

The benchmarks are **warm-memory**, not storage/device I/O, and parser peak
memory excludes the caller's source buffer and the I/O executor's allocations.

## Planned next steps

Phase 9: concurrent ASCII chunk processing using the tokenizer and numeric
converter already isolated under `src/decode/ascii/`.

Phase 10: variable-length **binary** list scanning; it can reuse the same
`ListColumn` interface.

## Deterministic dataset-matrix validation

Phase 8 has two complementary integration suites:

- `zig build test` runs `tests/ascii_matrix_test.zig`, a quick CI matrix
  covering seven ASCII dataset families with exact, record-by-record checks.
- `zig build test-ascii-large -Doptimize=ReleaseFast` runs the full matrix:

  | Data | Record count | Assertions |
  |---|---:|---|
  | XYZ f32 | 3,000,000 | All three typed columns and signed zero |
  | XYZ f64 | 3,000,000 | Exact typed values, scientific notation, signed zero |
  | XYZRGB mixed | 3,000,000 | All five properties and integer boundaries |
  | Wide custom element | 1,000,000 | All ten fields and unusual property order |
  | Triangle faces | 1,000,000 | List values/offsets and scalar-before-list metadata |
  | Mixed polygon faces | 100,000 | Empty/variable-length lists, independent offset buffers |
  | Zero-property element | 3,000,000 | Logical record progress and zero-column batches |

The shared `tests/ascii_dataset_support.zig` implements a virtual non-seekable
`std.Io.Reader` that repeats four deterministic lines on demand. It allocates
only a small header and fixed reader buffers, not an entire multi-million-row
fixture. Every batch is released immediately. Tests verify record counts,
per-element record offsets, globally increasing sequence numbers, decoded
values (including bit patterns for signed floating-point zero), list offsets,
absence of outstanding reservations, and peak parser-managed bytes <= 1 MiB.

These tests are *correctness and memory-regression tests*, not throughput
benchmarks. The small synthetic source intentionally repeats four records;
it does not measure file I/O, unpredictable numeric distributions, or allocator
RSS. The existing `bench-ascii` and `bench-concurrent` targets remain the
performance measurements. Keep the full multi-million-row matrix opt-in so
Debug builds and normal CI runs remain practical.
