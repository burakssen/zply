# Phase 13 M1 — Public API Inventory

Generated from `src/root.zig` and implementation modules at commit `55fd8db0`.

This inventory catalogs every public export, its signature, ownership/lifetime rules, error behavior, and stability classification. It serves as the baseline for API stabilization (M2–M3) and documentation (M8–M13).

---

## 1. Module Entry Point

```zig
const ply = @import("ply");  // Module name: "zply" in build.zig
```

**Current module name in build.zig**: `zply` (line 71)
**Import name used in examples**: `ply` (root.zig line 13)

**Decision needed**: Align module name (`zply`) with import name (`ply`) before release.

---

## 2. Core Types — Parser Lifecycle

### `Parser`

**Source**: `src/parser.zig` → re-exported via `src/root.zig:54`

#### Construction

```zig
pub fn init(
    allocator: std.mem.Allocator,
    io: std.Io,
    reader: *std.Io.Reader,
    options: Options,
) InitError!Parser
```

| Aspect | Detail |
|--------|--------|
| **Ownership** | Borrows `allocator`, `io`, `reader`; caller owns all three |
| **Lifetime** | All three must outlive the `Parser` instance |
| **Reader position** | Parser advances reader from current position; `body_offset` is relative |
| **Header parsing** | Synchronous, bounded, validates before returning |
| **Errors** | `InitError = error{InvalidConfiguration} || HeaderError` |
| **Partial init cleanup** | All parser allocations freed on failure; caller must NOT call `deinit` |

```zig
pub fn initDetailed(
    allocator: std.mem.Allocator,
    io: std.Io,
    reader: *std.Io.Reader,
    options: Options,
    diagnostic: *errors_mod.Diagnostic,
) InitError!Parser
```

| Aspect | Detail |
|--------|--------|
| **Purpose** | Capture header parsing diagnostic even on failure |
| **Diagnostic lifetime** | Borrowed for call duration only; no input-buffer or task pointers |
| **Reader on failure** | Left wherever it stopped; no rewind attempted |

#### Metadata Access

```zig
pub fn header(parser: *const Parser) *const Header
```

| Aspect | Detail |
|--------|--------|
| **Precondition** | Successful `init`; parser not in `.failed` or `.destroyed` state |
| **Lifetime** | Valid until `deinit()`; owned by parser |
| **Thread safety** | Read-only; no locking required |
| **Allocation** | None |

```zig
pub fn layouts(parser: *const Parser) []const layout_mod.ElementLayout
```

| Aspect | Detail |
|--------|--------|
| **Purpose** | Compiled record layouts for each element (offsets, widths, types) |
| **Precondition** | Same as `header()` |
| **Lifetime** | Valid until `deinit()` |
| **Note** | Lower-level than `header()`; for advanced consumers |

#### Streaming

```zig
pub fn next(parser: *Parser) NextError!?Batch
```

| Aspect | Detail |
|--------|--------|
| **Return** | `?Batch` — `null` = all declared records consumed (success, not EOF) |
| **Errors** | `NextError` — see §2.1 |
| **Batch lease** | Caller MUST `batch.release()` before next `next()` or `deinit()` |
| **Ordering** | Controlled by `Options.preserve_order` |
| **Memory pressure** | `MemoryPressure`, `BatchCapacityUnavailable` are recoverable (release batches, retry) |
| **Diagnostic** | `lastDiagnostic()` captures failure location |

```zig
pub const NextError = input.ProducerError || ascii_reader_mod.RecordError ||
    ascii_decode.record.DecodeError || binary_builder_mod.BuildError || error{
    InvalidRecordBoundary, CountOverflow,
    MemoryPressure, BatchCapacityUnavailable,
    InvalidLayout, InvalidColumnType, InvalidOutputCapacity,
};
```

#### Diagnostics

```zig
pub fn lastDiagnostic(parser: *const Parser) ?errors_mod.Diagnostic
pub fn binaryDiagnostic(parser: *const Parser) ?errors_mod.Diagnostic
pub fn asciiDiagnostic(parser: *const Parser) ?errors_mod.Diagnostic
```

| Aspect | Detail |
|--------|--------|
| **`lastDiagnostic`** | Unified snapshot of last `next()` failure (encoding-agnostic) |
| **`binaryDiagnostic`** | Encoding-specific binary record failure |
| **`asciiDiagnostic`** | Encoding-specific ASCII record failure |
| **Clearing** | `lastDiagnostic` cleared after successful `next()` call |

#### Statistics

```zig
pub fn memoryStats(parser: *const Parser) memory.MemoryStats
pub fn executionStats(parser: *const Parser) ExecutionStats
```

| Aspect | Detail |
|--------|--------|
| **`memoryStats`** | Live/reserved/peak bytes, pool breakdown, raw/decoded buffer bytes |
| **`executionStats`** | Admitted tasks, native submissions, inline decodes, max active decodes |
| **Thread safety** | Atomic reads for execution stats |

#### Teardown

```zig
pub fn deinit(parser: *Parser) void
```

| Aspect | Detail |
|--------|--------|
| **Precondition** | All batches released; parser in any non-`.destroyed` state |
| **Actions** | Cancels pending tasks, joins workers, destroys pools, frees all parser-owned memory |
| **Reader** | Never closed, never rewound, never read after completion |
| **Postcondition** | Parser state = `.destroyed`; no further method calls valid |

---

### `Parser.Options`

**Source**: `src/options.zig:57` → re-exported via `src/root.zig:65`

```zig
pub const Options = struct {
    memory_budget: usize = 256 * 1024 * 1024,
    chunk_size: usize = 4 * 1024 * 1024,
    preserve_order: bool = true,
    strict: bool = true,
    limits: Limits = .{},
    
    pub fn validate(options: Options) ValidationError!void
};
```

| Field | Default | Unit | Constraints |
|-------|---------|------|-------------|
| `memory_budget` | 256 MiB | bytes | > 0, ≥ `chunk_size` |
| `chunk_size` | 4 MiB | bytes | > 0, ≤ `memory_budget` |
| `preserve_order` | `true` | — | — |
| `strict` | `true` | — | — |
| `limits` | `Limits{}` | — | All nonzero; validated in `validate()` |

**Validation rules** (`Options.validate()`):
- `memory_budget > 0`
- `chunk_size > 0 && chunk_size ≤ memory_budget`
- All `Limits` fields nonzero
- `max_header_line_bytes ≤ max_header_bytes`
- `max_properties_per_element ≤ max_total_properties`
- `max_record_bytes ≥ ScalarType.max_width (8)`
- `max_ascii_token_bytes ≤ max_ascii_record_bytes`

---

### `Parser.Limits`

**Source**: `src/options.zig:22` → re-exported via `src/root.zig:68`

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

| Limit | Default | Purpose |
|-------|---------|---------|
| `max_header_bytes` | 1 MiB | Prevent unbounded header buffering |
| `max_header_line_bytes` | 64 KiB | Protect line scanner |
| `max_elements` | 1024 | Element count cap |
| `max_properties_per_element` | 4096 | Per-element property cap |
| `max_total_properties` | 16384 | Global property cap |
| `max_record_bytes` | 64 MiB | Fixed-width record cap |
| `max_ascii_record_bytes` | 8 MiB | ASCII line length cap |
| `max_ascii_token_bytes` | 4 KiB | Single token cap |
| `max_list_items_per_record` | 1M | List item count cap |

---

### `Parser.State` (public for diagnostics)

```zig
pub const State = enum {
    initializing,  // Header not yet parsed
    ready,         // Header parsed; next() may be called
    reading,       // Body records being consumed
    completed,     // All declared records consumed
    failed,        // Error terminated parser
    destroyed,     // deinit() called; terminal
};
```

---

### `Parser.ExecutionStats`

```zig
pub const ExecutionStats = struct {
    admitted_tasks: u64 = 0,
    native_submissions: u64 = 0,
    rejected_submissions: u64 = 0,
    inline_decodes: u64 = 0,
    max_inflight: usize = 0,
    active_decodes: usize = 0,
    max_active_decodes: usize = 0,
};
```

---

### `Parser.InitError`, `Parser.NextError`, `Parser.RawChunkError`

See §2.1 and `src/parser.zig:249–274`.

---

## 3. Header Model

### `Header`

**Source**: `src/format/header.zig:30` → re-exported via `src/root.zig:89`

```zig
pub const Header = struct {
    encoding: Encoding,
    version: Version,
    elements: []const Element = &.{},
    comments: []const []const u8 = &.{},
    obj_info: []const []const u8 = &.{},
    body_offset: u64 = 0,  // Relative to parser's initial reader position
    
    pub const supported_version: Version = .{ .major = 1, .minor = 0 };
    pub fn isSupportedVersion(version: Version) bool
    pub fn empty(encoding: Encoding) Header
    pub fn elementCount(header: Header) usize
    pub fn totalRecordCount(header: Header) error{NumericOverflow}!u64
};
```

| Field | Ownership | Lifetime |
|-------|-----------|----------|
| `elements` | Parser-owned (duplicated strings) | Until `Parser.deinit()` |
| `comments` | Parser-owned | Until `Parser.deinit()` |
| `obj_info` | Parser-owned | Until `Parser.deinit()` |
| `body_offset` | Relative to parser's initial reader position | — |

---

### `Element`

**Source**: `src/format/element.zig:28` → re-exported via `src/root.zig:86`

```zig
pub const Element = struct {
    name: []const u8,      // Parser-owned
    count: u64,            // Declared record count
    properties: []const Property,  // Ordered, parser-owned
    
    pub const SizeError = error{RecordSizeOverflow};
    pub fn addSize(a: usize, b: usize) SizeError!usize
    pub fn isFixedWidth(element: Element) bool
    pub fn fixedRecordSize(element: Element) SizeError!?usize
    pub fn countAsSize(element: Element) SizeError!usize
};
```

---

### `Property`

**Source**: `src/format/property.zig:22` → re-exported via `src/root.zig:83`

```zig
pub const Property = struct {
    name: []const u8,  // Parser-owned
    kind: Kind,
    
    pub const List = struct {
        count_type: IntegerType,
        item_type: ScalarType,
    };
    
    pub const Kind = union(enum) {
        scalar: ScalarType,
        list: List,
    };
    
    pub const ValidationError = error{EmptyPropertyName};
    
    pub fn scalar(name: []const u8, t: ScalarType) Property
    pub fn list(name: []const u8, count_type: IntegerType, item_type: ScalarType) Property
    pub fn isScalar(property: Property) bool
    pub fn isList(property: Property) bool
    pub fn scalarType(property: Property) ?ScalarType
    pub fn listInfo(property: Property) ?List
    pub fn fixedWidth(property: Property) ?usize  // null = variable width
    pub fn listCountWidth(property: Property) ?usize
    pub fn validate(property: Property) ValidationError!void
};
```

---

## 4. Format Types

### `Encoding`

**Source**: `src/format/types.zig:21` → re-exported via `src/root.zig:71`

```zig
pub const Encoding = enum {
    ascii,
    binary_little_endian,
    binary_big_endian,
    
    pub const ByteOrder = enum { none, little, big };
    pub fn isBinary(encoding: Encoding) bool
    pub fn byteOrder(encoding: Encoding) ByteOrder
    pub fn fromFormatName(name: []const u8) error{UnknownFormatName}!Encoding
    pub fn formatName(encoding: Encoding) []const u8
};
```

---

### `Version`

**Source**: `src/format/types.zig:68` → re-exported via `src/root.zig:74`

```zig
pub const Version = struct {
    major: u16,
    minor: u16,
};
```

---

### `ScalarType`

**Source**: `src/format/types.zig:79` → re-exported via `src/root.zig:77`

```zig
pub const ScalarType = enum {
    i8, u8, i16, u16, i32, u32, f32, f64,
    
    pub const max_width: usize = 8;
    pub fn byteWidth(scalar: ScalarType) usize
    pub fn isInteger(scalar: ScalarType) bool
    pub fn isFloating(scalar: ScalarType) bool
    pub fn isSigned(scalar: ScalarType) bool
    pub fn name(scalar: ScalarType) []const u8      // Canonical PLY name
    pub fn fromName(ply_name: []const u8) error{UnknownScalarType}!ScalarType
    pub fn fromNameCompatible(ply_name: []const u8) error{UnknownScalarType}!ScalarType
    pub fn zigType(scalar: ScalarType) type
    pub fn toIntegerType(scalar: ScalarType) error{NotAnIntegerType}!IntegerType
};
```

| ScalarType | PLY name | Zig type | Byte width |
|------------|----------|----------|------------|
| `i8` | `"char"` | `i8` | 1 |
| `u8` | `"uchar"` | `u8` | 1 |
| `i16` | `"short"` | `i16` | 2 |
| `u16` | `"ushort"` | `u16` | 2 |
| `i32` | `"int"` | `i32` | 4 |
| `u32` | `"uint"` | `u32` | 4 |
| `f32` | `"float"` | `f32` | 4 |
| `f64` | `"double"` | `f64` | 8 |

---

### `IntegerType`

**Source**: `src/format/types.zig:226` → re-exported via `src/root.zig:80`

```zig
pub const IntegerType = enum {
    i8, u8, i16, u16, i32, u32,
    
    pub fn scalar(integer: IntegerType) ScalarType
    pub fn byteWidth(integer: IntegerType) usize
    pub fn isSigned(integer: IntegerType) bool
    pub fn zigType(integer: IntegerType) type
    pub fn fromScalar(scalar_value: ScalarType) error{NotAnIntegerType}!IntegerType
};
```

---

## 5. Batch & Column Types

### `Batch`

**Source**: `src/batch/storage.zig:1006` → re-exported via `src/root.zig:57`

```zig
pub const Batch = struct {
    pub fn info(self: *const Batch) BatchInfo
    pub fn columnCount(self: *const Batch) usize
    pub fn column(self: *const Batch, index: usize) ?Column
    pub fn columnByPropertyIndex(self: *const Batch, index: usize) ?Column
    pub fn typedColumn(self: *const Batch, comptime T: type, index: usize) error{InvalidColumnType, InvalidPropertyIndex}![]const T
    pub fn listColumn(self: *const Batch, index: usize) error{InvalidColumnType, InvalidPropertyIndex}!ListColumn
    pub fn f64Column(self: *const Batch, index: usize) error{InvalidColumnType, InvalidPropertyIndex}![]const f64
    
    pub fn tryRelease(self: *Batch) error{InvalidBatchLease}!void
    pub fn release(self: *Batch) void  // Panics on invalid/released handle
};
```

| Aspect | Detail |
|--------|--------|
| **Lease model** | Single logical lease; copying handle does NOT duplicate lease |
| **`release()`** | Returns lease to parser pool; invalidates handle |
| **`tryRelease()`** | Returns error instead of panic |
| **Lifetime** | Valid until `release()`; parser must outlive all batches |
| **Thread safety** | Read-only access safe; `release()` must not race with reads |

---

### `BatchInfo`

**Source**: `src/batch/storage.zig:16` → re-exported via `src/root.zig:58`

```zig
pub const BatchInfo = struct {
    element_index: usize,
    first_record: u64,
    record_count: usize,
    sequence: u64,
};
```

| Field | Purpose |
|-------|---------|
| `element_index` | Element in header order |
| `first_record` | Global record index of first record in batch |
| `record_count` | Number of records in this batch |
| `sequence` | Completion sequence (for unordered delivery) |

---

### `Column`

**Source**: `src/batch/column.zig:42` → re-exported via `src/root.zig:59`

```zig
pub const Column = struct {
    property_index: usize,
    values: ScalarColumn,      // For scalar properties
    list: ?ListColumn = null,  // For list properties
};
```

---

### `ScalarColumn`

**Source**: `src/batch/column.zig:4` → re-exported via `src/root.zig:60`

```zig
pub const ScalarColumn = union(ScalarType) {
    i8: []const i8, u8: []const u8,
    i16: []const i16, u16: []const u16,
    i32: []const i32, u32: []const u32,
    f32: []const f32, f64: []const f64,
    
    pub fn scalarType(self: ScalarColumn) ScalarType
    pub fn len(self: ScalarColumn) usize
};
```

---

### `ListColumn`

**Source**: `src/batch/column.zig:25` → re-exported via `src/root.zig:61`

```zig
pub const ListColumn = struct {
    offsets: []const usize,  // Length = record_count + 1
    values: ScalarColumn,
    
    pub fn row(self: ListColumn, i: usize) ?ScalarColumn
};
```

| Invariant | Detail |
|-----------|--------|
| `offsets.len` | `record_count + 1` |
| `offsets[0]` | `0` |
| `offsets[record_count]` | `values.len()` |
| `offsets[i] ≤ offsets[i+1]` | Monotonically nondecreasing |

---

### `MemoryStats`

**Source**: `src/memory/budget.zig:7` → re-exported via `src/root.zig:62`

```zig
pub const MemoryStats = struct {
    budget_bytes: usize,
    live_bytes: usize,
    reserved_bytes: usize,
    peak_live_bytes: usize,
    peak_total_bytes: usize,
    batch_reductions: u64,
    pool_evictions: u64,
    bytes_reclaimed: usize,
    reservation_failures: u64,
    raw_buffer_bytes: usize = 0,
    decoded_buffer_bytes: usize = 0,
    retained_bytes: usize = 0,
    leased_bytes: usize = 0,
};
```

| Field | Meaning |
|-------|---------|
| `budget_bytes` | Configured `Options.memory_budget` |
| `live_bytes` | Currently committed allocations |
| `reserved_bytes` | Admitted but not yet committed |
| `peak_live_bytes` | High-water mark of `live_bytes` |
| `peak_total_bytes` | High-water mark of `live + reserved` |
| `leased_bytes` | Memory held by consumer-released batches |
| `raw_buffer_bytes` | Raw input chunk storage |
| `decoded_buffer_bytes` | Typed column storage |

---

## 6. Decoder API (Pure Binary)

**Source**: `src/decode/root.zig` → re-exported via `src/root.zig:104`

```zig
pub const decode = struct {
    pub const value = @import("value.zig");
    pub const scalar = @import("scalar.zig");
    pub const binary = @import("binary.zig");
    pub const record = @import("record.zig");
    
    pub const DecodeError = binary.DecodeError;
    pub const ScalarValue = value.ScalarValue;
    pub const FixedLayout = record.FixedLayout;
    pub const RecordView = record.RecordView;
    
    pub const decodeScalar = binary.decodeScalar;
    pub const decodeScalarAs = binary.decodeScalarAs;
    pub const endianFor = binary.endianFor;
    
    pub const decodeProperty = record.decodeProperty;
    pub const decodeRecord = record.decodeRecord;
    pub const decodeRange = record.decodeRange;
    pub const recordCountForRange = record.recordCountForRange;
    
    pub const binary_list_count = @import("binary/list_count.zig");
    pub const binary_preflight = @import("binary/preflight.zig");
};
```

**Status**: Re-exported for advanced consumers; not part of the primary streaming API. Documented as "internal decoder exports."

---

### `ScalarValue`

**Source**: `src/decode/value.zig:27` → re-exported via `src/root.zig:99` and `decode.root.zig:37`

```zig
pub const ScalarValue = union(ScalarType) {
    i8: i8, u8: u8, i16: i16, u16: u16,
    i32: i32, u32: u32, f32: f32, f64: f64,
    
    pub fn fromBits(scalar: ScalarType, pattern: u64) ScalarValue
    pub fn scalarType(value: ScalarValue) ScalarType
    pub fn byteWidth(value: ScalarValue) usize
    pub fn intExact(value: ScalarValue) ?i64
    pub fn floatExact(value: ScalarValue) ?f64
    pub fn bits(value: ScalarValue) u64
    pub fn bitsEqual(a: ScalarValue, b: ScalarValue) bool
};
```

---

## 7. Error & Diagnostic Model

### `Error`

**Source**: `src/errors.zig:80` → re-exported via `src/root.zig:107`

```zig
pub const Error = HeaderError || ProducerError ||
    error{ InvalidRecordBoundary, CountOverflow, TruncatedRecord, TruncatedListCount,
           TruncatedListPayload, InvalidReaderState, InvalidBuilderState, NegativeListCount } ||
    RecordError || DecodeError || error{
    MemoryPressure, BatchCapacityUnavailable, InvalidLayout, InvalidColumnType,
    InvalidOutputCapacity, InvalidConfiguration, InvalidBinaryRecord,
    TruncatedInput, ConcurrentFailure,
};
```

**Union of all parser errors** across phases.

---

### `HeaderError`

**Source**: `src/errors.zig:29`

```zig
pub const HeaderError = error{
    InvalidMagic, MissingFormat, UnsupportedEncoding, InvalidVersion,
    UnsupportedVersion, InvalidDirective, InvalidElement, InvalidProperty,
    InvalidScalarType, InvalidListCountType, DuplicateFormat, DuplicateElement,
    DuplicateProperty, InvalidName, HeaderTooLarge, HeaderLineTooLong,
    UnexpectedEndOfHeader, InvalidLineEnding, NumericOverflow,
    ResourceLimitExceeded, ReadFailed, OutOfMemory,
};
```

---

### `Diagnostic`

**Source**: `src/errors.zig:109` → re-exported via `src/root.zig:111`

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

| Field | Purpose |
|-------|---------|
| `category` | Coarse error grouping |
| `code` | Exact error value |
| `recovery` | Advisory: can caller retry? |
| `stage` | Where in pipeline error occurred |
| `byte_offset` | Relative to parser's initial reader position |
| `element_index` / `property_index` / `record_index` | Wide indices for large datasets |

---

## 8. Compiled Layouts (Advanced)

### `ElementLayout`

**Source**: `src/format/layout.zig:86` → re-exported via `src/root.zig:96`

```zig
pub const ElementLayout = struct {
    element_index: usize,
    fixed_record_size: ?usize,        // null = variable width
    minimum_record_size: usize,       // Sum of scalar widths + list count prefixes
    body_start_offset: ?u64,          // null if any prior element is variable
    fixed_body_size: ?u64,            // null if variable
    properties: []const PropertyLayout,
};
```

---

### `PropertyLayout`

**Source**: `src/format/layout.zig` → re-exported via `src/root.zig:92`

```zig
pub const PropertyLayout = struct {
    property_index: usize,
    fixed_offset: ?usize,             // null = variable position
    fixed_width: usize,               // 0 for list properties
    scalar_type: ?ScalarType,         // null for list properties
    binary_op: ?BinaryOp,             // Encoded decode operation
    // ... (list-specific fields)
};
```

---

## 9. Stability Classification

| Export | Stability | Notes |
|--------|-----------|-------|
| `Parser.init` | **Stable** | Primary entry point |
| `Parser.initDetailed` | **Stable** | Diagnostic opt-in |
| `Parser.header` | **Stable** | Immutable metadata |
| `Parser.layouts` | **Advanced** | For schema-aware consumers |
| `Parser.next` | **Stable** | Core streaming method |
| `Parser.deinit` | **Stable** | Required cleanup |
| `Parser.memoryStats` | **Stable** | Observability |
| `Parser.executionStats` | **Stable** | Observability |
| `Parser.lastDiagnostic` | **Stable** | Unified failure snapshot |
| `Parser.binaryDiagnostic` | **Encoding-specific** | May evolve |
| `Parser.asciiDiagnostic` | **Encoding-specific** | May evolve |
| `Options` | **Stable** | All fields documented |
| `Limits` | **Stable** | All fields documented |
| `Header` | **Stable** | Complete metadata |
| `Element` | **Stable** | Complete metadata |
| `Property` | **Stable** | Complete metadata |
| `Encoding` | **Stable** | Three canonical values |
| `Version` | **Stable** | Representational only |
| `ScalarType` | **Stable** | Eight canonical types |
| `IntegerType` | **Stable** | Six integer types |
| `Batch` | **Stable** | Lease model documented |
| `BatchInfo` | **Stable** | Complete metadata |
| `Column` / `ScalarColumn` / `ListColumn` | **Stable** | Typed column access |
| `MemoryStats` | **Stable** | Accounting breakdown |
| `Error` | **Stable** | Union of all errors |
| `Diagnostic` | **Stable** | Structured failure context |
| `decode` namespace | **Advanced** | Low-level decoder; stable but not primary API |
| `ScalarValue` | **Advanced** | Generic value representation |
| `ElementLayout` / `PropertyLayout` | **Internal/Advanced** | For schema introspection |

---

## 10. Known Issues for M2 (API Stabilization)

1. **Module name mismatch**: `build.zig` exports `"zply"` but examples use `@import("ply")`
2. **`binaryDiagnostic` / `asciiDiagnostic`**: Encoding-specific; consider deprecating in favor of `lastDiagnostic`
3. **`layouts()`**: Returns internal `ElementLayout`; may want a stable subset
4. **`decode` namespace**: Re-exports internal decoder; should be documented as "advanced" or moved
5. **`ScalarValue`**: Generic tagged union; bulk consumers use typed columns directly
6. **`PropertyLayout`**: Not fully documented; internal representation may change
7. **`Parser.State`**: Public enum; is it needed by consumers?
8. **`Options.strict`**: Compatibility mode (`fromNameCompatible`) not fully specified in docs

---

## 11. M1 Completion Checklist

- [x] Inventory all exports from `src/root.zig`
- [x] Document signatures, ownership, lifetimes, errors
- [x] Classify stability (Stable / Advanced / Internal)
- [x] Identify known issues for M2 resolution
- [ ] Review with team / stakeholders
- [ ] Freeze API surface for M2 stabilization

---

*End of M1 Public API Inventory*