# Phase 11 M5 — Header and ASCII numeric validation

This document describes the tested input profile. It is **not** a promise that
all third-party PLY writers use this profile. The production `Parser.init` and
`Parser.next` API remains unchanged.

## Header grammar

- The first nonblank directive must be exactly `ply`, followed by `format`.
- The format must be one of `ascii`, `binary_little_endian`, or
  `binary_big_endian` with version `1.0`. Encoding keywords remain
  case-sensitive even in compatibility mode.
- Structural directives have exact arity; unknown directives, extra
  arguments, unknown scalar widths, and floating-point list count types
  remain errors in both modes.
- Element counts are unsigned base-10 integers in the range `0..max(u64)`.
  Negative, signed-positive, fractional and overflowing declarations are
  rejected. Counts do not cause pre-allocation of all declared records.
- LF and CRLF terminators are accepted. A bare CR and an unfinished
  `end_header` line are rejected. Parsing stops at the first logical body byte.
- Leading spaces and tabs before a directive are accepted. A `comment` or
  `obj_info` excludes *one* separator immediately following its keyword and
  preserves all remaining payload bytes, even when the directive is indented.
- Strict mode rejects duplicate element/property names, nonprintable control
  bytes and non-ASCII names. Compatibility mode accepts duplicate names as
  separate declarations, permits non-ASCII names, and recognizes ASCII
  case-insensitive scalar names and `float32`/`float64` aliases. It does not
  relax encoding, record structure, list count types or version requirements.
- Both modes preserve element/property declaration order.

## ASCII numeric policy

The body uses a **one-record-per-line** profile. Only ASCII space and tab
separate tokens. The same numeric implementation validates scalar properties
and list items; lists additionally require nonnegative representable counts.

- Integers: optional leading `+` or (for signed types) `-`, followed by one or
  more decimal digits. Signed/unsigned widths are `8`, `16`, or `32` bits.
  Leading zeros are accepted. Hexadecimal, decimal points, exponents,
  embedded spaces and digit separators are rejected. Values outside the
  declared range yield `IntegerOverflow`.
- Floating-point: optional sign, digits with an optional decimal point, and
  optional `e`/`E` exponent with optional sign and required digits. At least
  one significand digit is required; `.5` and `1.` are valid. Conversion uses
  the compiler's `std.fmt.parseFloat`; finite decimal overflow that yields
  infinity is reported as `FloatOverflow`. Underflow follows that converter's
  rounding behavior (not treated as malformed syntax).
- Special tokens: exactly lowercase `nan`, `inf`, `+inf`, and `-inf` are
  accepted. `NaN`, `+nan`, `-nan`, `INF`, and `Infinity` are **not** supported.
  Textual NaN has no specified binary payload; binary NaN payload preservation
  is a separate binary-decoding concern.
- Negative zero must preserve the IEEE-754 sign bit for both f32 and f64.
- A nonempty malformed token produces `InvalidNumber`, distinct from
  integer/float overflow. The public `next()` path does not publish an
  incomplete batch when conversion fails.

## Scope and next checks

M5 adds targeted input-boundary tests and fixes indented metadata extraction.
It does **not** establish all Phase 11 robustness criteria. Binary boundary,
list offset, arithmetic and per-record resource verification belong to M6;
full allocator-failure, fragmentation, fuzzing and concurrency-order
verification remain separate milestones.

Tests: `tests/phase11_header_numeric_test.zig` and
`tests/phase11_numeric_stream_test.zig`, plus the existing header/ASCII suites.
