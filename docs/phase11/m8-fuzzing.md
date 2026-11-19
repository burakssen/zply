# Phase 11 M8 — bounded fuzzing and regression foundations

M8 adds four isolated Zig 0.17.1 coverage-guided targets in
`tests/fuzz/phase11_fuzz_test.zig`, without changing the Parser public API.
All targets import **only `zply_internals`**. Importing `zply` and
`zply_internals` into the same Zig compilation creates duplicate module
ownership for shared source files (e.g., `src/errors.zig`).

| Target filter | Coverage objective |
| --- | --- |
| `M8 fuzz arbitrary bounded PLY headers` | Header grammar, structural limits, stable diagnostics, and arena cleanup |
| `M8 fuzz ASCII numeric lexical boundaries` | Independent integer decimal oracle and float lexer robustness |
| `M8 fuzz valid generated ASCII and both binary encodings` | Schema-aware independent serialization, all three encodings, list contents, chunk sizes, reader trailing bytes, and budget accounting |
| `M8 fuzz targeted ASCII and binary body mutations` | Truncation, count corruption, malformed scalar tokens, terminal errors, and output shape invariants |

The existing Phase 10 `fuzz-binary-variable` step remains the deeper binary
variable-record structural oracle. M8 complements rather than replaces it.

## Deterministic and coverage-guided commands

```
zig build test
zig build test -Doptimize=ReleaseSafe
zig build test -Doptimize=ReleaseFast

# Isolated Phase 11 coverage-guided campaigns (opt-in):
zig build fuzz-phase11 --fuzz=1000
zig build fuzz-phase11 -Dphase11-fuzz-filter="M8 fuzz arbitrary" --fuzz=1000
zig build fuzz-phase11 -Dphase11-fuzz-filter="M8 fuzz valid" --fuzz=1000

# Existing deeper Phase 10 binary-variable fuzzing:
zig build fuzz-binary-variable --fuzz=1000
```

Normal `test` runs only deterministic oracle/corpus checks and the bounded
inline `std.testing.fuzz` replay; long coverage-guided exploration is opt-in.

## Bounds and oracles

- Generated documents use 1–8 records, 0–4 items per record, signed-16-bit
  list items, `u8` IDs and exactly representable integer-valued `f32`s.
- Generation/serialization is independent of production parsing, scanning,
  and layout compilation. The expected records are constructed first and
  compared with the typed columns returned by `Parser.next()`.
- Input mutation affects **only** the body so that well-formed headers reach
  record scanners and decoders. Failures must have the corresponding
  structured diagnostic; successful batches must satisfy list invariants.
- Memory limits are deliberately much larger than the small generated
  fixtures to avoid confusing admission pressure with fuzzed input defects.
- All produced batches are released before parser destruction; no test
  builds the entire input dynamically from attacker-supplied sizes.

## Limitations / next steps

A passing regression/corpus test does not prove all possible PLY inputs safe.
M8 currently covers a bounded representative schema and should be extended
with independent structured schema generation for multiple elements, all
canonical scalar widths, multiple list properties, strict and compatibility
modes, and arbitrary reader fragmentation. Release gating requires sustained
fuzzing plus later fault-injection, differential and concurrency campaigns.
