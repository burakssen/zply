# Phase 11 M15 regression corpus

All files here were **hand-authored for this project** (no external samples or third-party licensing).
They are minimal, deterministic examples, not a claim to represent all PLY implementations.
No random generator is involved; random seed: **N/A** for every row.

| Filename | Expected | Encoding | Targeted condition | Category |
|---|---|---|---|---|
| `valid_ascii_xyz_rgb.ply` | `valid` | `ascii` | xyz/rgb columns | `none` |
| `valid_little_xyz_rgb.ply` | `valid` | `binary_little_endian` | xyz/rgb columns | `none` |
| `valid_big_xyz_rgb.ply` | `valid` | `binary_big_endian` | xyz/rgb columns | `none` |
| `valid_ascii_mixed.ply` | `valid` | `ascii` | face list + scalar, camera element | `none` |
| `valid_little_mixed.ply` | `valid` | `binary_little_endian` | face list + scalar, camera element | `none` |
| `valid_big_mixed.ply` | `valid` | `binary_big_endian` | face list + scalar, camera element | `none` |
| `invalid_magic.ply` | `InvalidMagic` | `ascii` | invalid file signature | `header` |
| `invalid_version.ply` | `UnsupportedVersion` | `ascii` | unsupported PLY version | `version` |
| `invalid_duplicate_format.ply` | `DuplicateFormat` | `ascii` | duplicate format directive | `header` |
| `invalid_list_count_type.ply` | `InvalidListCountType` | `ascii` | floating point list count declaration | `scalar_type` |
| `invalid_ascii_number.ply` | `InvalidNumber` | `ascii` | invalid numeric token | `record` |
| `invalid_ascii_u8_overflow.ply` | `IntegerOverflow` | `ascii` | unsigned integer overflow | `record` |
| `invalid_little_truncated_u32.ply` | `TruncatedBody` | `binary_little_endian` | short fixed-width scalar | `truncation` |
| `invalid_big_truncated_u32.ply` | `TruncatedBody` | `binary_big_endian` | short fixed-width scalar | `truncation` |
| `invalid_little_list_payload.ply` | `TruncatedListPayload` | `binary_little_endian` | incomplete list item payload | `truncation` |
| `invalid_big_list_payload.ply` | `TruncatedListPayload` | `binary_big_endian` | incomplete list item payload | `truncation` |
| `invalid_little_list_count.ply` | `TruncatedListCount` | `binary_little_endian` | incomplete 32-bit list count | `truncation` |
| `invalid_big_list_count.ply` | `TruncatedListCount` | `binary_big_endian` | incomplete 32-bit list count | `truncation` |
| `invalid_negative_list_count.ply` | `NegativeListCount` | `binary_little_endian` | negative signed list count | `record` |

Replayed by `tests/phase11_regression_test.zig` through `zig build test-regression` and `zig build test`.
Valid cases are also tested with a four-byte trailer not included in the fixture to verify declared-body termination.
Failure cases assert the exact public error and its diagnostic category; non-seekable fragmented readers are exercised.

Newly discovered fuzz failures should be minimized, added here with a new test-case entry and expected outcome, and documented with their seed and reproduction options.
