//! Internal decoder exports: the pure binary decoding engine.
//!
//! The decoder is independent of `parser.zig` (and of all I/O): it
//! consumes compiled layouts from `format/layout.zig` and borrowed byte
//! slices, and produces typed values. The parser may import these
//! modules, but they never import the parser — this keeps the dependency
//! direction one-way and the decoder reusable from streaming, batched,
//! projected, and concurrent execution paths alike.
//!
//! Layering:
//!
//! ```text
//! ScalarType + Encoding      (format/types.zig)
//!          ↓
//! scalar.decodeScalar        (primitive, concrete Zig types)
//!          ↓
//! binary.decodeScalar        (type-driven dispatch → ScalarValue)
//!          ↓
//! FixedLayout (validated)    (record.zig)
//!          ↓
//! decodeProperty / RecordView / decodeRecord / decodeRange
//! ```
//!
//! Error model: `DecodeError` is the shared binary-decode error set;
//! individual functions declare narrow subsets. No decode error is ever
//! an I/O or allocation error, because the decoder performs neither.

pub const value = @import("value.zig");
pub const scalar = @import("scalar.zig");
pub const binary = @import("binary.zig");
pub const record = @import("record.zig");

/// The shared error set of the binary decoder.
pub const DecodeError = binary.DecodeError;

/// Re-exported for convenience at the decoder root.
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

/// Phase 10 endian-aware binary list-count primitive.
pub const binary_list_count = @import("binary/list_count.zig");
pub const binary_preflight = @import("binary/preflight.zig");
