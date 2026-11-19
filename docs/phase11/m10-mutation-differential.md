# Phase 11 M10 — Mutation and differential testing

M9 checks parser output against a model constructed *before* serialization.
M10 adds a second, independent oracle which reads the serialized PLY bytes
again. Neither oracle nor the mutation generator imports production header,
layout, numeric, record boundary or decoding code.

## Bounded reference decoder

`tests/property/reference_decoder.zig` is a deliberately small, sequential
PLY 1.0 reader. It recognizes canonical scalar names, schema order, per-line
ASCII records, 8/16/32-bit signed and unsigned list counts, and both binary
byte orders. It decodes actual list prefixes, scalar fields and values from
serialized bytes, preserving integer signedness and exact float bits.

The reference decoder intentionally supports only M9's bounded generated
schemas (three elements, eight properties per element, six records each, four
items per list), and is **not** a second public PLY library. Its limits are
independent from those of the production parser. It ignores bytes after the
declared body; a truncated declaration is an error, not completion.

## Three-way comparison

`tests/property/mutation_differential_test.zig` compares:

1. M9's *pre-serialization* reference cells, schemas and list lengths.
2. M10's *independently parsed byte-level* cells and header.
3. The production parser's batch metadata, typed columns, raw scalar bits,
   list offsets and list items, and logical reader position.

Tests vary the seed, all three encodings, and chunk size. Comparison does not
require matching batch boundaries. Parser memory statistics are checked under
the configured budget. For valid input the input suffix remains available in
the borrowed reader.

## Mutation categories and precedence

- Header: bad magic, repeated format declaration, unsupported version, invalid
  type, floating-point list count, and negative element declaration. These must
  be rejected, not silently skipped or reinterpreted.
- ASCII: corrupted numeric tokens, malformed signed list counts, and incomplete
  declared records. Rejection may happen after a valid earlier batch.
- Binary LE/BE: truncated scalar fields, oversized list counts, and negative
  signed list counts. Count validation must happen before reading or allocating
  the declared payload.
- Coverage-guided: seed and encoding selection, header corruption, cuts inside
  the body, random body byte replacement, changes *after* the declared body,
  and oversized list counts in a known list-first schema.

For malformed input, the two decoders may report different error names or
reject at different stages. The test verifies that the production parser either
rejects a known-invalid input with a stable diagnostic or returns exactly the
independently decoded valid records. A random mutation may remain valid.

The M10 harness is bounded and allocation-clean. It is not an interoperability
claim for third-party files, noncanonical aliases, NaN spellings in ASCII or
high-volume stress input. Broader metamorphic tests and external readers are
separate work.

## Local verification

```sh
zig build test
zig build test -Doptimize=ReleaseSafe
zig build test -Doptimize=ReleaseFast
zig build fuzz-differential --fuzz=1000
```

`fuzz-differential` filters to a single target, avoiding Zig 0.17.1's
multi-target fuzz discovery ambiguity. Reproduce a failure with the relevant
seed, encoding and mutation selector, minimize it and add the resulting case to
permanent tests before changing the parser.
