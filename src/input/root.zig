//! Internal streaming input exports: the sequential producer pipeline.
//!
//! The input layer is independent of `parser.zig` (it never imports the
//! parser) and of any concrete source type: it works exclusively through
//! the caller's `*std.Io.Reader` and stores no borrowed pointers in its
//! own state. `parser.zig` owns a `Producer` and a `RawBuffer` and feeds
//! them the header, layouts, and reader per operation.
//!
//! Layering:
//!
//! ```text
//! ChunkPlan  (planner.zig — pure sizing mathematics)
//!     ↓
//! RawBuffer  (buffer.zig — one reusable bounded allocation)
//!     ↓
//! Producer   (producer.zig — state machine + exact-length reads)
//!     ↓
//! RawChunk   (chunk.zig — complete-record descriptor, borrowed bytes)
//! ```
//!
//! Error model: `ProducerError` distinguishes I/O failures (`ReadFailed`,
//! `TruncatedBody`), unsupported structures (`UnsupportedEncoding`,
//! `UnsupportedVariableLengthElement`), resource constraints
//! (`RecordTooLarge`, `InsufficientBufferCapacity`, `ResourceLimitExceeded`),
//! and state misuse (`InvalidProducerState`) — never one generic
//! invalid-file error. Phase 5 will map these into the public `Error` set
//! with diagnostic context.

pub const chunk = @import("chunk.zig");
pub const planner = @import("planner.zig");
pub const buffer = @import("buffer.zig");
pub const ascii_record_reader = @import("ascii_record_reader.zig");
pub const ascii_producer = @import("ascii_producer.zig");
pub const ascii_chunk = @import("ascii_chunk.zig");
pub const producer = @import("producer.zig");
pub const pool = @import("pool.zig");

pub const RawChunk = chunk.RawChunk;
pub const ChunkPlan = planner.ChunkPlan;
pub const RawBuffer = buffer.RawBuffer;
pub const Producer = producer.Producer;
pub const ProducerError = producer.ProducerError;
pub const RawBufferPool = pool.RawBufferPool;

/// Phase 10 pure variable-width binary record scanner (no Reader access).
pub const binary_boundary = @import("binary_boundary.zig");
/// Incremental, non-seekable variable-length binary record reader.
pub const binary_variable = @import("binary_variable.zig");

/// Bounded record-aligned staging for variable-width binary elements.
pub const binary_chunk_builder = @import("binary_chunk_builder.zig");
