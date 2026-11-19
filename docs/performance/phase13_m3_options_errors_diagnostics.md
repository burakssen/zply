# Phase 13 M3 — Options, Errors & Diagnostics Review

This document finalizes the public configuration, error taxonomy, and diagnostic contracts for the v0.1.0 release.

---

## 1. Options — Final Specification

### `Options`

```zig
pub const Options = struct {
    memory_budget: usize = 256 * 1024 * 1024,
    chunk_size: usize = 4 * 1024 * 1024,
    preserve_order: bool = true,
    strict: bool = true,
    limits: Limits = .{},

    pub fn validate(options: Options) ValidationError!void;
};
```

| Field | Default | Unit | Validation | Description |
|-------|---------|------|------------|-------------|
| `memory_budget` | 256 MiB | bytes | > 0, ≥ `chunk_size` | Max parser-managed accounted capacity (live + reserved) |
| `chunk_size` | 4 MiB | bytes | > 0, ≤ `memory_budget` | Preferred raw input chunk size (hint, not guarantee) |
| `preserve_order` | `true` | — | — | Return batches in source record order |
| `strict` | `true` | — | — | Strict PLY validation (see §4) |
| `limits` | `Limits{}` | — | All nonzero | Defensive caps (see below) |

### Validation Rules (`Options.validate()`)

```zig
pub fn validate(options: Options) ValidationError!void {
    const l = options.limits;

    // Core budget constraints
    if (options.memory_budget == 0) return error.InvalidConfiguration;
    if (options.chunk_size == 0) return error.InvalidConfiguration;
    if (options.chunk_size > options.memory_budget) return error.InvalidConfiguration;

    // Header limits
    if (l.max_header_bytes == 0) return error.InvalidConfiguration;
    if (l.max_header_line_bytes == 0) return error.InvalidConfiguration;
    if (l.max_header_line_bytes > l.max_header_bytes) return error.InvalidConfiguration;

    // Schema limits
    if (l.max_elements == 0) return error.InvalidConfiguration;
    if (l.max_properties_per_element == 0) return error.InvalidConfiguration;
    if (l.max_total_properties == 0) return error.InvalidConfiguration;
    if (l.max_properties_per_element > l.max_total_properties) return error.InvalidConfiguration;

    // ASCII/record limits
    if (l.max_ascii_record_bytes == 0 or l.max_ascii_token_bytes == 0 or l.max_list_items_per_record == 0) return error.InvalidConfiguration;
    if (l.max_ascii_token_bytes > l.max_ascii_record_bytes) return error.InvalidConfiguration;

    // Binary record limits
    if (l.max_record_bytes == 0) return error.InvalidConfiguration;
    if (l.max_record_bytes < types.ScalarType.max_width) return error.InvalidConfiguration;  // 8 bytes
}
```

### `Limits`

```zig
pub const Limits = struct {
    max_header_bytes: usize = 1024 * 1024,
    max_header_line_bytes: usize = 64 * 1024,
    max_elements: usize = 1024,
    max_properties_per_element: usize = 4096,
    max_total_properties: usize = 16384,
    max_record_bytes: usize = 64 * 1024 * 1024,
    max_ascii_record_bytes: usize = 8 * 1024 * 1024,
    max_ascii_token_bytes: usize = 4 * 1024,
    max_list_items_per_record: usize = 1_000_000,
};
```

| Limit | Default | Rationale |
|-------|---------|-----------|
| `max_header_bytes` | 1 MiB | Prevents unbounded header buffering; typical headers < 10 KiB |
| `max_header_line_bytes` | 64 KiB | Protects line scanner; single property lines rarely exceed 1 KiB |
| `max_elements` | 1024 | PLY files rarely have > 10 elements; prevents schema explosion |
| `max_properties_per_element` | 4096 | Wide but reasonable; PLY 1.0 doesn't define a limit |
| `max_total_properties` | 16384 | Global cap across all elements |
| `max_record_bytes` | 64 MiB | Fixed-width record cap; catches absurd schemas early |
| `max_ascii_record_bytes` | 8 MiB | ASCII line length cap; protects tokenizer |
| `max_ascii_token_bytes` | 4 KiB | Single token cap; prevents pathological numbers |
| `max_list_items_per_record` | 1M | List item count cap; prevents allocation attacks |

**Design note**: Limits are intentionally generous. They protect against malicious/unreasonable inputs, not typical use cases. Legitimate files with unusual schemas should work without hitting these.

---

## 2. Error Taxonomy — Final Specification

### Error Hierarchy

```
Error
├── HeaderError (Phase 2)
├── ProducerError (Phase 4)
├── RecordError (Phase 8 — ASCII)
├── DecodeError (Phase 8 — ASCII)
├── BuildError (Phase 10 — Binary variable)
└── Generic errors:
    ├── InvalidConfiguration
    ├── InvalidRecordBoundary
    ├── CountOverflow
    ├── MemoryPressure          ← recoverable
    ├── BatchCapacityUnavailable ← recoverable
    ├── InvalidLayout
    ├── InvalidColumnType
    ├── InvalidOutputCapacity
    ├── InvalidBinaryRecord
    ├── TruncatedInput
    └── ConcurrentFailure
```

### `HeaderError` — Complete Set

```zig
pub const HeaderError = error{
    // Magic/format
    InvalidMagic,
    MissingFormat,
    UnsupportedEncoding,
    InvalidVersion,
    UnsupportedVersion,
    InvalidDirective,

    // Element/property
    InvalidElement,
    InvalidProperty,
    InvalidScalarType,
    InvalidListCountType,
    DuplicateFormat,
    DuplicateElement,
    DuplicateProperty,
    InvalidName,

    // Limits
    HeaderTooLarge,
    HeaderLineTooLong,
    UnexpectedEndOfHeader,
    InvalidLineEnding,
    NumericOverflow,
    ResourceLimitExceeded,

    // I/O
    ReadFailed,
    OutOfMemory,
};
```

### `ProducerError` — Streaming Pipeline

```zig
pub const ProducerError = error{
    InvalidConfiguration,
    UnexpectedEndOfHeader,
    HeaderTooLarge,
    HeaderLineTooLong,
    InvalidLineEnding,
    NumericOverflow,
    ResourceLimitExceeded,
    ReadFailed,
    OutOfMemory,
    InvalidRecordBoundary,
    RecordTooLarge,
    TruncatedAsciiBody,
    InvalidAsciiRecord,
};
```

### `RecordError` (ASCII) — `src/input/ascii_record_reader.zig`

```zig
pub const RecordError = error{
    TruncatedAsciiBody,
    InvalidAsciiRecord,
    InvalidLineEnding,
    RecordTooLarge,
    ReadFailed,
    OutOfMemory,
    SizeOverflow,
};
```

### `DecodeError` (ASCII) — `src/decode/ascii/record.zig`

```zig
pub const DecodeError = error{
    InvalidAsciiRecord,
    TokenTooLong,
    InvalidNumber,
    IntegerOverflow,
    FloatOverflow,
    SizeOverflow,
};
```

### `BuildError` (Binary variable) — `src/input/binary_chunk_builder.zig`

```zig
pub const BuildError = RecordError || error{InvalidBuilderState};
```

### Generic Errors (Parser-level)

```zig
error{
    InvalidConfiguration,        // Options.validate() failure
    InvalidRecordBoundary,       // Record boundary violated
    CountOverflow,               // List count exceeds usize
    MemoryPressure,              // Recoverable: release batches + retry
    BatchCapacityUnavailable,    // Recoverable: release batches + retry
    InvalidLayout,               // Internal layout inconsistency
    InvalidColumnType,           // Consumer requested wrong type
    InvalidOutputCapacity,       // Consumer output slice too small
    InvalidBinaryRecord,         // Binary decode mismatch
    TruncatedInput,              // Input ended before declared records
    ConcurrentFailure,           // std.Io reported failure
};
```

---

## 3. Recovery Classification — Final

Every error maps to exactly one recovery class:

```zig
pub const Recovery = enum {
    terminal,           // Parser state invalid; never retry
    resource_pressure,  // May clear after batch release / task completion
    context_dependent,  // Requires config change or budget increase
};
```

### Complete Mapping

| Error | Recovery | Notes |
|-------|----------|-------|
| `InvalidConfiguration` | `terminal` | Fix options before retry |
| `InvalidMagic` | `terminal` | — |
| `MissingFormat` | `terminal` | — |
| `UnsupportedEncoding` | `terminal` | — |
| `InvalidVersion` | `terminal` | — |
| `UnsupportedVersion` | `terminal` | — |
| `InvalidDirective` | `terminal` | — |
| `InvalidElement` | `terminal` | — |
| `InvalidProperty` | `terminal` | — |
| `InvalidScalarType` | `terminal` | — |
| `InvalidListCountType` | `terminal` | — |
| `DuplicateFormat` | `terminal` | — |
| `DuplicateElement` | `terminal` | — |
| `DuplicateProperty` | `terminal` | — |
| `InvalidName` | `terminal` | — |
| `HeaderTooLarge` | `terminal` | Increase `max_header_bytes` |
| `HeaderLineTooLong` | `terminal` | Increase `max_header_line_bytes` |
| `UnexpectedEndOfHeader` | `terminal` | Input truncated |
| `InvalidLineEnding` | `terminal` | — |
| `NumericOverflow` | `terminal` | Increase limits or fix input |
| `ResourceLimitExceeded` | `context_dependent` | Increase limits / budget |
| `ReadFailed` | `terminal` | I/O failure |
| `OutOfMemory` | `context_dependent` | Increase budget / reduce chunk |
| `InvalidRecordBoundary` | `terminal` | Corrupted data |
| `RecordTooLarge` | `terminal` | Increase `max_record_bytes` |
| `TruncatedAsciiBody` | `terminal` | Input ended in record |
| `InvalidAsciiRecord` | `terminal` | Grammar violation |
| `TruncatedRecord` | `terminal` | Input ended in record |
| `TruncatedListCount` | `terminal` | Input ended in count |
| `TruncatedListPayload` | `terminal` | Input ended in list items |
| `InvalidReaderState` | `terminal` | Internal error |
| `InvalidBuilderState` | `terminal` | Internal error |
| `NegativeListCount` | `terminal` | Signed count < 0 |
| `InvalidAsciiRecord` (decode) | `terminal` | Token grammar error |
| `TokenTooLong` | `terminal` | Increase `max_ascii_token_bytes` |
| `InvalidNumber` | `terminal` | Not a valid number |
| `IntegerOverflow` | `terminal` | Value exceeds type range |
| `FloatOverflow` | `terminal` | Value exceeds float range |
| `SizeOverflow` | `terminal` | Arithmetic overflow |
| `InvalidBuilderState` | `terminal` | Internal error |
| `InvalidConfiguration` | `terminal` | Fix options |
| `InvalidBinaryRecord` | `terminal` | Binary decode mismatch |
| `TruncatedInput` | `terminal` | EOF before declared records |
| `ConcurrentFailure` | `terminal` | std.Io failure |
| `MemoryPressure` | **`resource_pressure`** | **Release batches, retry `next()`** |
| `BatchCapacityUnavailable` | **`resource_pressure`** | **Release batches, retry `next()`** |
| `InvalidLayout` | `terminal` | Internal error |
| `InvalidColumnType` | `terminal` | Consumer bug |
| `InvalidOutputCapacity` | `terminal` | Consumer bug |

---

## 4. Diagnostic — Final Specification

```zig
pub const Diagnostic = struct {
    category: Category,
    code: ?anyerror = null,
    recovery: Recovery = .terminal,
    stage: Stage = .input,
    chunk_sequence: ?u64 = null,
    column_number: ?usize = null,
    expected: ?u64 = null,
    actual: ?u64 = null,
    failure_byte_offset: ?u64 = null,
    line_number: ?u64 = null,
    directive: ?Directive = null,
    element_index: ?u64 = null,
    property_index: ?u64 = null,
    record_index: ?u64 = null,
    byte_offset: ?u64 = null,          // Relative to parser's initial position
    token_byte_offset: ?u64 = null,    // ASCII token position

    pub const Stage = enum { configuration, header, schema, input, preflight, decode, scheduling, memory };
    pub const Recovery = enum { terminal, resource_pressure, context_dependent };
    pub const Directive = enum { magic, format, element, property, comment, obj_info, end_header };
    pub const Category = enum { configuration, header, encoding, version, scalar_type, record, truncation, resource_limit, execution, memory, reader };

    pub fn recoveryFor(err: anyerror) Recovery
    pub fn fromError(err: anyerror, stage: Stage) Diagnostic
    pub fn categoryFor(err: anyerror) Category
    pub fn stageFor(err: anyerror) Stage
};
```

### Field Definitions

| Field | Type | Always Present? | Description |
|-------|------|-----------------|-------------|
| `category` | `Category` | Yes | Coarse error grouping |
| `code` | `?anyerror` | No | Exact error value (null in legacy manual construction) |
| `recovery` | `Recovery` | Yes | Advisory retry guidance |
| `stage` | `Stage` | Yes | Pipeline stage where error detected |
| `chunk_sequence` | `?u64` | No | Task sequence for concurrent failures |
| `column_number` | `?usize` | No | 1-based ASCII token column |
| `expected` / `actual` | `?u64` | No | Expected vs actual value (e.g., count) |
| `failure_byte_offset` | `?u64` | No | Precise failure cursor |
| `line_number` | `?u64` | No | 1-based header line (header errors) |
| `directive` | `?Directive` | No | Header directive being parsed |
| `element_index` | `?u64` | No | Element index in header order |
| `property_index` | `?u64` | No | Property index within element |
| `record_index` | `?u64` | No | Record index within element |
| `byte_offset` | `?u64` | No | Document-relative byte offset (matches `Header.body_offset`) |
| `token_byte_offset` | `?u64` | No | ASCII token start position |

### Access Patterns

```zig
// Unified failure snapshot (covers all encodings)
const diag = parser.lastDiagnostic() orelse return;

// Encoding-specific (for legacy/advanced use)
const bin_diag = parser.binaryDiagnostic();
const ascii_diag = parser.asciiDiagnostic();

// Initialization failure detail
var diag: Diagnostic = undefined;
const parser = ply.Parser.initDetailed(allocator, io, &reader, .{}, &diag) catch |err| {
    // diag populated even though init failed
    log.error("Header parse failed: {}", .{diag});
    return err;
};
```

---

## 5. Strict vs Compatibility Mode — Final Specification

### `Options.strict = true` (Default)

| Aspect | Behavior |
|--------|----------|
| Scalar type lookup | `ScalarType.fromName()` — exact case-sensitive match |
| Duplicate element names | Rejected (`DuplicateElement`) |
| Duplicate property names | Rejected (`DuplicateProperty`) |
| Structural name charset | ASCII printable only (`InvalidName`) |
| Unknown directives | Error (`InvalidDirective`) |
| Blank lines in header | Skipped |
| Line endings | LF or CRLF required |

### `Options.strict = false` (Compatibility)

| Aspect | Behavior |
|--------|----------|
| Scalar type lookup | `ScalarType.fromNameCompatible()` — case-insensitive + aliases |
| Duplicate element names | Kept as separate entries (last wins for layout) |
| Duplicate property names | Kept as separate entries (last wins for layout) |
| Structural name charset | Extended? (TBD: currently same as strict) |
| Unknown directives | Skipped with warning? (TBD) |
| Blank lines in header | Skipped |
| Line endings | LF or CRLF required |

### `ScalarType.fromNameCompatible()` Accepted Names

| Canonical | Aliases accepted in compatible mode |
|-----------|--------------------------------------|
| `char` (i8) | `CHAR`, `Char`, `int8`, `INT8` |
| `uchar` (u8) | `UCHAR`, `Uchar`, `uint8`, `UINT8` |
| `short` (i16) | `SHORT`, `Short`, `int16`, `INT16` |
| `ushort` (u16) | `USHORT`, `Ushort`, `uint16`, `UINT16` |
| `int` (i32) | `INT`, `Int`, `int32`, `INT32` |
| `uint` (u32) | `UINT`, `Uint`, `uint32`, `UINT32` |
| `float` (f32) | `FLOAT`, `Float`, `float32`, `FLOAT32` |
| `double` (f64) | `DOUBLE`, `Double`, `float64`, `FLOAT64` |

**Note**: The compatible mode only affects case sensitivity and standard aliases. It does NOT accept nonstandard types like `float16`, `int64`, or `uint64`.

---

## 6. M3 Completion Checklist

- [x] `Options` fields, defaults, validation rules finalized
- [x] `Limits` fields, defaults, rationale documented
- [x] Complete error taxonomy (`HeaderError`, `ProducerError`, `RecordError`, `DecodeError`, `BuildError`, generic)
- [x] Recovery classification for every error
- [x] `Diagnostic` fields and access patterns finalized
- [x] Strict vs compatibility mode specified
- [ ] Review with team / stakeholders
- [ ] Freeze for M4 (Package layout)

---

*End of M3 Options, Errors & Diagnostics Review*