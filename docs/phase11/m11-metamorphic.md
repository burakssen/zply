# Phase 11 M11 — Metamorphic verification

The parser's public reader-first behavior is unchanged. This milestone adds
`tests/property/metamorphic_test.zig` and an isolated `fuzz-metamorphic` build
step. It tests invariants under changes that are not supposed to affect the
logical PLY records.

## Test invariants

| Property | Enforcement |
| --- | --- |
| Reader fragmentation | A fixed reader and non-seekable readers fragmented as `[1]`, `[2,3,5,7]`, and `[64,1,128,3]` decode the same M9 reference records. |
| Chunk partition | Chunk hints of 64, 128, 256, and 512 bytes all reconstruct the same logical record set; physical batch boundaries may differ. |
| Budget | A 512 KiB, 2 MiB, and 4 MiB budget all produce the original records; each parser checks both current and peak accounted usage. These are deliberately sufficient budgets, not exhaustion tests. |
| Execution | `std.testing.io` fallback and `std.Io.Threaded`, ordered and unordered, independently verify exact records and one delivery per record. A 40,000-record binary list fixture forces actual native submissions. |
| Endianness | Independently constructed cells from the same seed match across ASCII, little-endian binary, and big-endian binary; each decoding result is compared with those cells bit-for-bit. |
| Batch partition | Element index and record offset identify every logical record. Per-record visitation detects gaps and duplicates, without relying on batch boundaries or delivery order. |
| Lists | Offsets begin at zero, advance by each record's expected list length, terminate at the value array length, and typed values match the reference cell. |
| Retained lease | A first batch remains leased and is re-verified after processing later batches. No batch handle is copied or released twice. |
| Metadata | Inserting an unrelated `comment` line changes the document's body offset but not its decoded records. |
| Error classification | Invalid ASCII, short fixed binary, and short list fixtures return the same diagnostic category with fallback/Threaded and ordered/unordered modes; a large final-record truncation additionally verifies this after native read-ahead. |

All generated-document comparisons use the independent M9 reference data,
not data obtained by decoding the production parser's output. Float values
are checked using their raw bits; neither signed zero nor integer signedness
is erased by numeric comparisons.

## Commands

```sh
zig build test
zig build test -Doptimize=ReleaseSafe
zig build test -Doptimize=ReleaseFast
zig build fuzz-metamorphic --fuzz=1000
```

The deterministic cases are part of the normal test target. Only the
`M11 fuzz metamorphic` entry is selected by the isolated fuzz step, so the
Zig coverage-guided runner never has to choose among multiple fuzz tests.

## Scope and remaining work

The test generator's records are intentionally small and deterministic. A
separate 40,000-record binary fixture exercises genuine native task submission
with lists, both byte orders, and unordered delivery. This milestone does not
prove all possible scheduler interleavings, arbitrary consumer lease misuse,
reader-failure cleanup, or allocation-failure recovery; later milestones own
those stress and fault-injection matrices.

The borrowed reader is checked at its **logical** cursor (trailing `TAIL`
bytes are still available). Underlying physical prefetch is not assumed to
match that cursor.
