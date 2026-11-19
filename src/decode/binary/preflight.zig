//! Phase 10 allocation-free sizing of a trusted, record-aligned binary chunk.
//!
//! The chunk builder already validated list counts while finding boundaries.
//! This planner checks the structural metadata and computes the exact column
//! payload needed for output admission without parsing numeric values again.
const std = @import("std");
const layout_mod = @import("../../format/layout.zig");
const chunks = @import("../../input/binary_chunk_builder.zig");

pub const Error = error{ InvalidLayout, InvalidRecordBoundary, SizeOverflow };

pub const Plan = struct {
    record_count: usize,
    raw_bytes: usize,
    decoded_bytes: usize,
};

/// `totals` has one count per property (zero for every scalar).
/// This excludes pool descriptors and allocator capacity overhead; those
/// must still be included by the caller's existing budget admission logic.
pub fn decodedBytes(layout: *const layout_mod.ElementLayout, n: usize, totals: []const usize) Error!usize {
    if (layout.fixed_record_size != null or n == 0 or layout.properties.len != totals.len) return error.InvalidLayout;
    const offset_count = std.math.add(usize, n, 1) catch return error.SizeOverflow;
    var result: usize = 0;
    for (layout.properties, totals, 0..) |property, count, index| {
        if (property.property_index != index) return error.InvalidLayout;
        const op = property.binary_op orelse return error.InvalidLayout;
        const bytes: usize = switch (op) {
            .scalar => |s| blk: {
                if (count != 0 or property.scalar_type != s.scalar_type or
                    property.fixed_width != s.width or s.width != s.scalar_type.byteWidth()) return error.InvalidLayout;
                break :blk std.math.mul(usize, n, s.width) catch return error.SizeOverflow;
            },
            .list => |l| blk: {
                if (property.scalar_type != null or property.fixed_width != null or
                    l.count_width != l.count_type.byteWidth() or l.item_width != l.item_type.byteWidth()) return error.InvalidLayout;
                const offset_bytes = std.math.mul(usize, offset_count, @sizeOf(usize)) catch return error.SizeOverflow;
                const value_bytes = std.math.mul(usize, count, l.item_width) catch return error.SizeOverflow;
                break :blk std.math.add(usize, offset_bytes, value_bytes) catch return error.SizeOverflow;
            },
        };
        result = std.math.add(usize, result, bytes) catch return error.SizeOverflow;
    }
    return result;
}

pub fn plan(chunk: chunks.Chunk, layout: *const layout_mod.ElementLayout) Error!Plan {
    const expected_offsets = std.math.add(usize, chunk.record_count, 1) catch return error.SizeOverflow;
    if (chunk.element_index != layout.element_index or chunk.record_count == 0 or
        chunk.offsets.len != expected_offsets or
        chunk.offsets[0] != 0 or chunk.offsets[chunk.offsets.len - 1] != chunk.bytes.len)
        return error.InvalidRecordBoundary;
    for (0..chunk.record_count) |i| {
        const first = chunk.offsets[i];
        const end = chunk.offsets[i + 1];
        if (first >= end or end > chunk.bytes.len or end - first < layout.minimum_record_size)
            return error.InvalidRecordBoundary;
    }
    return .{
        .record_count = chunk.record_count,
        .raw_bytes = chunk.bytes.len,
        .decoded_bytes = try decodedBytes(layout, chunk.record_count, chunk.list_item_totals),
    };
}
