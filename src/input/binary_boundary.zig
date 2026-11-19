//! Phase 10: pure, allocation-free binary variable-record boundary scanning.
//!
//! A scan either identifies one complete record or requests more bytes for a
//! particular property. The caller owns its input storage and may extend it
//! and retry; no I/O, pointer arithmetic on untrusted counts, or allocations
//! happen here. Streaming will later use an incremental cursor to avoid
//! repeated full scans of very large, partially received records.

const std = @import("std");
const layout_mod = @import("../format/layout.zig");
const list_count = @import("../decode/binary/list_count.zig");

pub const ScanError = error{
    InvalidLayout,
    NegativeListCount,
    CountOverflow,
    ListTooLarge,
    RecordTooLarge,
    SizeOverflow,
};

pub const Limits = struct {
    max_record_bytes: usize,
    max_list_items_per_record: usize,
};

pub const Stage = enum { scalar, list_count, list_items };

pub const Incomplete = struct {
    /// Index of the structural property that needs more data.
    property_index: usize,
    stage: Stage,
    /// Minimum number of input bytes required to continue scanning.
    /// Measured from the beginning of the record, not an absolute file offset.
    required_total: usize,
};

pub const Complete = struct {
    byte_length: usize,
    /// Aggregate count across every list in this record, checked for overflow.
    total_list_items: usize,
};

pub const ScanResult = union(enum) {
    complete: Complete,
    incomplete: Incomplete,
};

/// Scan a single binary record prefix from its first byte.
///
/// `counts_out` is optional and, when supplied, must have at least one entry
/// per property. The entry for every scalar property is zero. Values written
/// on an incomplete scan are temporary: consume them only on `.complete`.
/// Counts are retained *per property*, including when several lists use
/// different count and item types.
pub fn scanRecord(
    layout: *const layout_mod.ElementLayout,
    endian: std.builtin.Endian,
    bytes: []const u8,
    limits: Limits,
    counts_out: ?[]usize,
) ScanError!ScanResult {
    if (counts_out) |counts| {
        if (counts.len < layout.properties.len) return error.InvalidLayout;
        @memset(counts[0..layout.properties.len], 0);
    }

    var offset: usize = 0;
    var total_list_items: usize = 0;

    for (layout.properties, 0..) |prop, property_index| {
        if (prop.property_index != property_index) return error.InvalidLayout;
        const op = prop.binary_op orelse return error.InvalidLayout;
        switch (op) {
            .scalar => |s| {
                if (s.width != s.scalar_type.byteWidth() or prop.scalar_type != s.scalar_type)
                    return error.InvalidLayout;
                const end = try checkedEnd(offset, s.width, limits.max_record_bytes);
                if (end > bytes.len) return .{ .incomplete = .{
                    .property_index = property_index,
                    .stage = .scalar,
                    .required_total = end,
                } };
                offset = end;
            },
            .list => |l| {
                if (prop.scalar_type != null or
                    l.count_width != l.count_type.byteWidth() or
                    l.item_width != l.item_type.byteWidth()) return error.InvalidLayout;

                const count_end = try checkedEnd(offset, l.count_width, limits.max_record_bytes);
                if (count_end > bytes.len) return .{ .incomplete = .{
                    .property_index = property_index,
                    .stage = .list_count,
                    .required_total = count_end,
                } };

                const count = list_count.decodeListCount(l.count_type, endian, bytes[offset..count_end]) catch |err| switch (err) {
                    error.InsufficientBytes => return error.InvalidLayout, // checked above
                    error.NegativeListCount => return error.NegativeListCount,
                    error.CountOverflow => return error.CountOverflow,
                };
                if (count > limits.max_list_items_per_record) return error.ListTooLarge;
                const payload_bytes = std.math.mul(usize, count, l.item_width) catch return error.SizeOverflow;
                const payload_end = try checkedEnd(count_end, payload_bytes, limits.max_record_bytes);
                total_list_items = std.math.add(usize, total_list_items, count) catch return error.SizeOverflow;
                if (counts_out) |counts| counts[property_index] = count;
                if (payload_end > bytes.len) return .{ .incomplete = .{
                    .property_index = property_index,
                    .stage = .list_items,
                    .required_total = payload_end,
                } };
                offset = payload_end;
            },
        }
    }
    if (offset < layout.minimum_record_size) return error.InvalidLayout;
    return .{ .complete = .{
        .byte_length = offset,
        .total_list_items = total_list_items,
    } };
}

fn checkedEnd(start: usize, width: usize, max_record_bytes: usize) ScanError!usize {
    const end = std.math.add(usize, start, width) catch return error.SizeOverflow;
    if (end > max_record_bytes) return error.RecordTooLarge;
    return end;
}
