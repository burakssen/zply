# Phase 11 M9 — Structured valid-PLY generation

The M8 generator exercises one fixed schema. M9 adds a separate independent,
seeded reference model (`tests/property/document_generator.zig`) and a
parser-level verification suite (`document_generator_test.zig`). The generator
never imports the production tokenizer, parser, schema compiler or decoder.

## Generation and reference model

- A seed fixes schema, record counts, property declarations, typed values, and
  list lengths **before** choosing the serialization format.
- The same model serializes to ASCII, binary little-endian and binary
  big-endian, preserving exact scalar bits. Float test values are selected
  from binary-exact decimal numbers, including negative zero; this intentionally
  avoids making incorrect promises about ASCII NaN payload serialization.
- A bounded buffer (32 KiB), up to three elements, eight properties per
  element, six records per element and four items per list limit generated
  state and execution time. Generator overflow is an explicit error.
- Seed families 0–3 force every canonical scalar type; interleaved multiple
  lists and scalar properties; zero-count/zero-property elements; and varying
  signed/unsigned list count widths (8/16/32-bit). Families 4–5 also randomize
  schema shapes and property types.
- The generated document contains `TAIL` after its declared body, which the
  streaming parser must leave unread.

## Oracle and invariants

The test inspects the parsed header and every published batch, comparing
property types, list count types, order and exact scalar bit patterns against
*the generator's pre-serialization reference cells*. The parser is never used
as an oracle for its own output.

The test verifies exact record counts and first-record indices per element;
list offsets (length = batch rows + 1, starting at zero, monotonically
advancing by generated list lengths, ending at values length); independent list
buffers; output element/column order; parser budget telemetry; and trailing
reader bytes. It checks seed determinism and cross-encoding reference equality.

## Commands

```
zig build test
zig build test -Doptimize=ReleaseSafe
zig build test -Doptimize=ReleaseFast
zig build fuzz-valid-ply --fuzz=1000
```

The isolated fuzz target avoids Zig's multi-target fuzz discovery ambiguity.
Report the seed when minimizing failures. This adds generated valid-schema
coverage but **is not** a full differential reference decoder of external
PLY bytes: that is a separate Phase 11 milestone. Reader fragmentation,
concurrent scheduling, non-finite float handling, and larger-scale stress
remain distinct tests.
