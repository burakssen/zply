//! Descriptors for complete record ranges: the `RawChunk` contract.
//!
//! A chunk is the unit the streaming producer hands to the Phase 3
//! decoder: a contiguous byte range that always contains whole records
//! of exactly one element, plus the metadata needed for order
//! verification, diagnostics, and (later) concurrent result reordering.
//!
//! A chunk *borrows* its bytes from a reusable input buffer: the slice is
//! valid only until that buffer is refilled, resized, or released. The
//! consumer must finish decoding a chunk before asking the producer for
//! the next one.

/// A contiguous, complete-record section of the PLY body.
///
/// Invariants of every chunk the producer emits:
///
/// 1. All records belong to exactly one element (`element_index`).
/// 2. The chunk contains no partial records.
/// 3. `first_record` identifies the first logical record within the
///    element (elements restart record numbering at zero).
/// 4. `record_count > 0`.
/// 5. `sequence` increases monotonically across the whole body — it
///    never resets between elements (Phase 7 reordering relies on this).
/// 6. `byte_offset` is the PLY-relative offset of the chunk's first byte
///    (i.e. relative to the parser's initial logical reader position,
///    matching `Header.body_offset` conventions).
/// 7. `bytes` is a borrowed view; valid only for the documented period.
///
/// For a nonzero fixed record width R: `bytes.len == record_count * R`.
/// For a zero-width element: `bytes.len == 0` even when `record_count`
/// is greater than zero (logical records that occupy no bytes).
pub const RawChunk = struct {
    /// Index of the element in the PLY header.
    element_index: usize,

    /// First record index within that element.
    first_record: u64,

    /// Number of complete records represented.
    record_count: u64,

    /// Monotonic chunk sequence across the whole body.
    sequence: u64,

    /// Byte offset of the chunk's first byte, relative to the parser's
    /// initial logical reader position.
    byte_offset: u64,

    /// Borrowed view into an input buffer. Length is exactly
    /// `record_count * record_width` (which is 0 for zero-width
    /// elements).
    bytes: []const u8,

    /// Validates the structural invariants that do not require the
    /// header: positive record count, nonzero-width/length agreement,
    /// and (given the record width) the exact byte length. Callers that
    /// know the record width pass it; pass `null` only when the width is
    /// unknown at the call site (the producer always knows it).
    pub fn validateAgainstWidth(
        chunk: RawChunk,
        record_width: ?usize,
    ) error{InvalidChunk}!void {
        if (chunk.record_count == 0) return error.InvalidChunk;
        if (record_width) |width| {
            const expected = std.math.mul(
                u64,
                chunk.record_count,
                @intCast(width),
            ) catch return error.InvalidChunk;
            if (chunk.bytes.len != expected) return error.InvalidChunk;
        }
    }
};

const std = @import("std");

test "zero-width chunk carries logical records without bytes" {
    const chunk: RawChunk = .{
        .element_index = 3,
        .first_record = 65536,
        .record_count = 65536,
        .sequence = 9,
        .byte_offset = 200,
        .bytes = &.{},
    };
    try chunk.validateAgainstWidth(0);
    // Nonzero width would contradict the empty slice.
    try std.testing.expectError(error.InvalidChunk, chunk.validateAgainstWidth(4));
}

test "nonzero-width chunk length must equal count times width" {
    var bytes: [12]u8 = @splat(0);
    const chunk: RawChunk = .{
        .element_index = 0,
        .first_record = 0,
        .record_count = 3,
        .sequence = 0,
        .byte_offset = 0,
        .bytes = &bytes,
    };
    try chunk.validateAgainstWidth(4);
    try std.testing.expectError(error.InvalidChunk, chunk.validateAgainstWidth(5));
}

test "zero record count is always invalid" {
    const chunk: RawChunk = .{
        .element_index = 0,
        .first_record = 0,
        .record_count = 0,
        .sequence = 0,
        .byte_offset = 0,
        .bytes = &.{},
    };
    try std.testing.expectError(error.InvalidChunk, chunk.validateAgainstWidth(null));
    try std.testing.expectError(error.InvalidChunk, chunk.validateAgainstWidth(0));
}
