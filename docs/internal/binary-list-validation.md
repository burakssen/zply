# Phase 11 M6 — Binary and list validation

The Phase 10 implementation already checks binary count signedness, record
size arithmetic, byte-order interpretation, staged read truncation, and list
item capacities. M6 adds focused validation at the **prepared output boundary**
and tests representative multi-list records independently of the scanner.

## Contracts

- `scanRecord` checks a signed count before using it as a size, then enforces
  the configured list-item limit before checked payload-length arithmetic.
  A complete scan returns a byte width and per-property counts; an incomplete
  scan identifies the next required byte extent, without consuming input.
- `binary_preflight.plan` requires positive-length records, offsets starting
  at zero and ending at the chunk length, monotonically increasing boundaries,
  and a totals entry for each property. It does **not** rescan list item counts:
  these are trusted metadata from the earlier producer scan.
- `decodePreparedBinaryVariable` validates all output column capacities and
  types before writing even the first offset. On a destination preflight error
  it leaves caller-supplied list offsets untouched. After successful decoding,
  each list has `record_count + 1` offsets, the first offset is zero, offsets
  are nondecreasing, and the last equals the initialized item count.
- Binary fixed-width input and the variable-length producer retain their
  existing byte-alignment, input fragmentation, and error contracts.

## Focused tests

`tests/phase11_binary_list_validation_test.zig` covers equal logical records
in little- and big-endian encodings, mixed scalar/list property ordering,
empty lists, independent count types, exact published list offsets, malformed
chunk boundaries, signed negative counts, configured item-count and record
byte limits, and preflight failure atomicity.

These tests are deterministic regression cases, **not** exhaustive proof for
arbitrary malformed data. The later fuzzing, fault-injection, and concurrent
error-order milestones remain necessary. No additional public API or new
worker-count option is introduced.
