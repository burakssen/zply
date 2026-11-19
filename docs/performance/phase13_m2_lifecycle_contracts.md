# Phase 13 M2 — Parser & Batch Lifecycle Contracts

This document formalizes the ownership, lifetime, and error contracts for the public API surface. It serves as the authoritative reference for M8–M13 documentation and M16 release validation.

---

## 1. Parser Lifecycle

### State Machine

```
initializing ──▶ ready ──▶ reading ──▶ completed
     │              │          │
     └──────────────┴──────────┴──────▶ failed (terminal)
any state ─────────────────────────────▶ destroyed (via deinit)
```

### State Definitions

| State | Meaning | Valid Operations |
|-------|---------|------------------|
| `initializing` | Header parsing in progress | None (internal) |
| `ready` | Header parsed, body not started | `header()`, `layouts()`, `next()`, `deinit()` |
| `reading` | Body records being consumed | `next()`, `deinit()` |
| `completed` | All declared records consumed | `deinit()` |
| `failed` | Terminal error occurred | `deinit()`, `lastDiagnostic()` |
| `destroyed` | `deinit()` called | None |

### Method Contracts

#### `init(allocator, io, reader, options) InitError!Parser`

| Aspect | Contract |
|--------|----------|
| **Preconditions** | `allocator`, `io`, `reader` valid; `options.validate()` succeeds |
| **Reader consumption** | Advances reader through header (including `end_header\n`) |
| **On success** | Parser in `ready` state; reader at first body byte |
| **On failure** | All parser allocations freed; reader left at failure point; **no rewind** |
| **Caller responsibility** | Must NOT call `deinit()` on failed result |
| **Errors** | `InitError = error{InvalidConfiguration} \| HeaderError` |

#### `initDetailed(..., diagnostic) InitError!Parser`

| Aspect | Contract |
|--------|----------|
| **Purpose** | Capture header parsing diagnostic on failure |
| **`diagnostic` lifetime** | Borrowed for call duration only |
| **On failure** | `diagnostic` populated with location; reader at failure point |
| **On success** | `diagnostic` unmodified (caller may check `code == null`) |

#### `header(parser) *const Header`

| Aspect | Contract |
|--------|----------|
| **Precondition** | Parser in `ready`, `reading`, or `completed` state |
| **Lifetime** | Valid until `deinit()` |
| **Ownership** | Parser-owned; no allocation on call |
| **Thread safety** | Read-only, no locking |

#### `layouts(parser) []const ElementLayout`

| Aspect | Contract |
|--------|----------|
| **Precondition** | Same as `header()` |
| **Lifetime** | Valid until `deinit()` |
| **Use case** | Schema-aware consumers needing compiled offsets/widths |

#### `next(parser) NextError!?Batch`

| Aspect | Contract |
|--------|----------|
| **Precondition** | Parser in `ready` or `reading` state |
| **Return** | `?Batch` — `null` = all declared records consumed (success) |
| **Batch lease** | Caller MUST `batch.release()` before next `next()` or `deinit()` |
| **Ordering** | Controlled by `Options.preserve_order` |
| **Memory pressure** | `MemoryPressure`, `BatchCapacityUnavailable` recoverable via `release()` + retry |
| **Errors** | `NextError` (see below) |
| **Diagnostic** | `lastDiagnostic()` captures failure on error return |

#### `deinit(parser) void`

| Aspect | Contract |
|--------|----------|
| **Precondition** | All batches released; parser in any non-`destroyed` state |
| **Actions** | Cancel pending tasks → join workers → destroy pools → free all parser memory |
| **Reader** | Never closed, never rewound, never read after completion |
| **Postcondition** | Parser state = `destroyed`; no further method calls valid |

#### `memoryStats(parser) MemoryStats`

| Aspect | Contract |
|--------|----------|
| **Precondition** | Parser not in `destroyed` state |
| **Returns** | Snapshot of live/reserved/peak bytes, pool breakdown |
| **Thread safety** | Atomic reads |

#### `executionStats(parser) ExecutionStats`

| Aspect | Contract |
|--------|----------|
| **Precondition** | Parser not in `destroyed` state |
| **Returns** | Admitted tasks, native submissions, inline decodes, max active |
| **Thread safety** | Atomic reads for `active_decodes` / `max_active_decodes` |

#### `lastDiagnostic(parser) ?Diagnostic`

| Aspect | Contract |
|--------|----------|
| **Returns** | Unified snapshot of last `next()` failure |
| **Clearing** | Reset to `null` after successful `next()` |
| **Encoding-agnostic** | Includes recovery guidance |

---

## 2. Error Contracts

### `InitError`

```zig
InitError = error{InvalidConfiguration} || HeaderError
```

| Error | Category | Recoverable? | Reader Advanced? |
|-------|----------|--------------|------------------|
| `InvalidConfiguration` | configuration | No (fix options) | No |
| `InvalidMagic` | header | No | Yes (past `ply`) |
| `MissingFormat` | header | No | Yes |
| `UnsupportedEncoding` | encoding | No | Yes |
| `InvalidVersion` | version | No | Yes |
| `UnsupportedVersion` | version | No | Yes |
| `InvalidDirective` | header | No | Yes |
| `InvalidElement` | header | No | Yes |
| `InvalidProperty` | header | No | Yes |
| `InvalidScalarType` | scalar_type | No | Yes |
| `InvalidListCountType` | scalar_type | No | Yes |
| `DuplicateFormat` | header | No | Yes |
| `DuplicateElement` | header | No | Yes |
| `DuplicateProperty` | header | No | Yes |
| `InvalidName` | header | No | Yes |
| `HeaderTooLarge` | resource_limit | No | Yes |
| `HeaderLineTooLong` | resource_limit | No | Yes |
| `UnexpectedEndOfHeader` | truncation | No | Yes (at EOF) |
| `InvalidLineEnding` | header | No | Yes |
| `NumericOverflow` | resource_limit | No | Yes |
| `ResourceLimitExceeded` | resource_limit | Context-dependent | Yes |
| `ReadFailed` | reader | No | Yes (at failure) |
| `OutOfMemory` | memory | Context-dependent | Maybe |

### `NextError`

```zig
NextError = ProducerError || RecordError || DecodeError || BuildError || error{
    InvalidRecordBoundary, CountOverflow,
    MemoryPressure, BatchCapacityUnavailable,
    InvalidLayout, InvalidColumnType, InvalidOutputCapacity,
};
```

| Error | Category | Recovery | Notes |
|-------|----------|----------|-------|
| `MemoryPressure` | memory | **resource_pressure** | Release batches, retry |
| `BatchCapacityUnavailable` | memory | **resource_pressure** | Release batches, retry |
| `ResourceLimitExceeded` | resource_limit | **context_dependent** | May need config change |
| `OutOfMemory` | memory | **context_dependent** | May need budget increase |
| `TruncatedInput` | truncation | terminal | Input ended early |
| `InvalidRecordBoundary` | record | terminal | Corrupted data |
| `CountOverflow` | record | terminal | List count too large |
| `InvalidLayout` | schema | terminal | Internal error |
| `InvalidColumnType` | preflight | terminal | Type mismatch |
| `InvalidOutputCapacity` | preflight | terminal | Output too small |
| `ProducerError` variants | input | various | Reader/stream errors |
| `RecordError` (ASCII) | record | various | Line grammar errors |
| `DecodeError` (ASCII) | decode | terminal | Token/number errors |
| `BuildError` (binary) | input | various | Boundary/list errors |

### Recovery Classification

```zig
pub const Recovery = enum {
    terminal,           // Never retry; parser state invalid
    resource_pressure,  // May clear after batch release / task completion
    context_dependent,  // Requires inspection (config change, budget increase)
};
```

**Critical rule**: Never re-enter a `Parser` in `.failed` state. Call `deinit()` and create a new parser.

---

## 3. Batch Ownership Model

### Lease Semantics

```
Parser Pool ───▶ Batch (lease) ───▶ Consumer
     │                              │
     └───────── release() ◀─────────┘
```

| Rule | Enforcement |
|------|-------------|
| One logical lease per batch | `Batch` copy does NOT duplicate lease |
| `release()` returns lease to pool | Required before `deinit()` |
| Stale handle access invalid | `tryRelease()` returns error; `release()` panics |
| Parser must outlive all batches | Use-after-deinit is invalid |
| Columns stable until release | Subsequent `next()` does not overwrite leased columns |

### Batch Methods

```zig
pub fn info(self: *const Batch) BatchInfo
pub fn columnCount(self: *const Batch) usize
pub fn column(self: *const Batch, index: usize) ?Column
pub fn columnByPropertyIndex(self: *const Batch, index: usize) ?Column
pub fn typedColumn(self: *const Batch, comptime T: type, index: usize) error{InvalidColumnType, InvalidPropertyIndex}![]const T
pub fn listColumn(self: *const Batch, index: usize) error{InvalidColumnType, InvalidPropertyIndex}!ListColumn

pub fn tryRelease(self: *Batch) error{InvalidBatchLease}!void  // Returns error on stale handle
pub fn release(self: *Batch) void  // Panics on stale handle
```

### Column Access Patterns

```zig
// Scalar property
const x: []const f64 = try batch.f64Column(0);
// or
const x: []const f32 = try batch.typedColumn(f32, 0);

// List property
const indices: ListColumn = try batch.listColumn(0);
for (0..batch.info().record_count) |i| {
    if (indices.row(i)) |row| {
        // row is ScalarColumn of list items
    }
}
```

---

## 4. Memory Budget Contract

### Invariant

```
live_bytes + reserved_bytes ≤ Options.memory_budget
```

### What's Included

| Component | Accounted? |
|-----------|------------|
| Header metadata (names, comments, layouts) | ✅ Yes |
| Raw input chunks | ✅ Yes |
| Batch pool storage (raw + decoded) | ✅ Yes |
| Task descriptors, queue backing | ✅ Yes |
| Staged partial records | ✅ Yes |
| Internal scratch buffers | ✅ Yes |

### What's Excluded

| Component | Accounted? |
|-----------|------------|
| Caller-owned reader buffers | ❌ No |
| Caller-owned source storage | ❌ No |
| `std.Io` executor internal allocations | ❌ No |
| Thread stacks | ❌ No |
| Allocator internal overhead | ❌ No |
| Process RSS / OS page cache | ❌ No |

### Pressure Behavior

1. **Admission controller** verifies chunk + decoded output fits before reading
2. **Adaptive batch sizing** reduces record count if needed
3. **Reclamation** evicts idle incompatible pool slots
4. **Consumer backpressure** — if all batches leased, `MemoryPressure` / `BatchCapacityUnavailable`
5. **Consumer must release** at least one batch to make progress

---

## 5. Reader Contract

### Invariants

1. **Borrowed only** — Parser never owns, closes, destroys, seeks, or resets reader
2. **Advances only forward** — `body_offset` relative to parser's initial position
3. **Non-seekable supported** — Mid-stream readers valid; no rewind on error
4. **Buffer untouched** — Parser never touches reader's internal buffer
5. **No concurrent reads** — Caller must not read from same reader during parsing
6. **No destruction reads** — Parser stops at declared records; trailing data untouched

### On Failure

- Reader left at failure point (no rewind)
- Failed `init`: reader advanced through consumed header lines
- Failed `next`: reader advanced through consumed body bytes

---

## 6. Concurrency Contract

### Execution Model

```
Parser (single producer) ──▶ std.Io (caller-owned) ──▶ Native tasks
                    │                          ▲
                    └────── Completion Queue ──┘
```

| Aspect | Contract |
|--------|----------|
| **Worker control** | `std.Io` implementation controls thread count / execution |
| **Parser role** | Admits tasks based on memory budget and chunk size |
| **No parser thread pool** | Never creates own workers |
| **Sequential fallback** | When `std.Io` reports unavailable, decodes inline |
| **Ordered delivery** | Joins completions in sequence order (`preserve_order=true`) |
| **Unordered delivery** | Returns completions as ready (`preserve_order=false`) |

### Statistics

```zig
ExecutionStats {
    admitted_tasks: u64,           // Tasks accepted into pipeline
    native_submissions: u64,       // Tasks submitted to std.Io
    rejected_submissions: u64,     // std.Io returned unavailable
    inline_decodes: u64,           // Tasks decoded synchronously
    max_inflight: usize,           // Peak admitted (not executing)
    active_decodes: usize,         // Currently executing (atomic)
    max_active_decodes: usize,     // Peak concurrently executing
}
```

---

## 7. Ordering Guarantees

| Mode | `Options.preserve_order` | Delivery |
|------|--------------------------|----------|
| Ordered | `true` (default) | Batches returned in source record order |
| Unordered | `false` | Batches returned in completion order |

**Batch metadata for reordering**:
```zig
BatchInfo {
    element_index: usize,
    first_record: u64,    // Global record index
    record_count: usize,
    sequence: u64,        // Completion sequence (unordered mode)
}
```

---

## 8. Compatibility Mode (`Options.strict`)

| Aspect | `strict = true` (default) | `strict = false` |
|--------|---------------------------|------------------|
| Scalar type names | Exact case-sensitive match | Case-insensitive + aliases |
| Duplicate element names | Rejected | Kept as separate entries |
| Duplicate property names | Rejected | Kept as separate entries |
| Structural names | ASCII only | Extended? (TBD) |
| Unknown directives | Error | Skip? (TBD) |

**TODO for M2**: Document exact compatibility mode behavior.

---

## 9. M2 Completion Checklist

- [x] Parser state machine documented
- [x] `init` / `initDetailed` contracts formalized
- [x] `next` lease semantics formalized
- [x] `deinit` contract formalized
- [x] Error recovery classification complete
- [x] Batch ownership model formalized
- [x] Memory budget invariant documented
- [x] Reader invariants documented
- [x] Concurrency model documented
- [x] Ordering guarantees documented
- [ ] Compatibility mode (`strict = false`) fully specified
- [ ] Review with team / stakeholders
- [ ] Freeze for M3 (Options/Errors/Diagnostics review)

---

*End of M2 Parser & Batch Lifecycle Contracts*