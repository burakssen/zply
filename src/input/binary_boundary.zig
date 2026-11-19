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

/// Incremental structural scanner. One instance tracks progress through a
/// single record so that a partially received list payload does not cause the
/// already-scanned properties and list count to be reinterpreted on every
/// subsequent input extension. The scanner borrows the compiled layout and
/// never allocates.
pub const Scanner = struct {
    layout: *const layout_mod.ElementLayout,
    endian: std.builtin.Endian,
    limits: Limits,
    counts_out: ?[]usize,
    property_index: usize = 0,
    offset: usize = 0,
    total_list_items: usize = 0,
    /// State for the list currently being scanned.
    list_count: usize = 0,
    list_payload_end: usize = 0,
    in_list_payload: bool = false,
    started: bool = false,

    pub fn init(
        layout: *const layout_mod.ElementLayout,
        endian: std.builtin.Endian,
        limits: Limits,
        counts_out: ?[]usize,
    ) ScanError!Scanner {
        if (counts_out) |counts| {
            if (counts.len < layout.properties.len) return error.InvalidLayout;
        }
        return .{
            .layout = layout,
            .endian = endian,
            .limits = limits,
            .counts_out = counts_out,
        };
    }

    /// Resets per-record state. Called by the streaming reader when a new
    /// record begins; repeated `scan` calls on the same record resume.
    pub fn reset(self: *Scanner) void {
        self.property_index = 0;
        self.offset = 0;
        self.total_list_items = 0;
        self.list_count = 0;
        self.list_payload_end = 0;
        self.in_list_payload = false;
        self.started = true;
        if (self.counts_out) |counts| @memset(counts[0..self.layout.properties.len], 0);
    }

    pub fn scan(self: *Scanner, bytes: []const u8) ScanError!ScanResult {
        if (!self.started) self.reset();
        while (self.property_index < self.layout.properties.len) {
            const property_index = self.property_index;
            const prop = self.layout.properties[property_index];
            if (prop.property_index != property_index) return error.InvalidLayout;
            const op = prop.binary_op orelse return error.InvalidLayout;
            switch (op) {
                .scalar => |s| {
                    if (s.width != s.scalar_type.byteWidth() or prop.scalar_type != s.scalar_type)
                        return error.InvalidLayout;
                    const end = try checkedEnd(self.offset, s.width, self.limits.max_record_bytes);
                    if (end > bytes.len) return .{ .incomplete = .{
                        .property_index = property_index,
                        .stage = .scalar,
                        .required_total = end,
                    } };
                    self.offset = end;
                    self.property_index += 1;
                },
                .list => |l| {
                    if (prop.scalar_type != null or
                        l.count_width != l.count_type.byteWidth() or
                        l.item_width != l.item_type.byteWidth()) return error.InvalidLayout;

                    if (!self.in_list_payload) {
                        const count_end = try checkedEnd(self.offset, l.count_width, self.limits.max_record_bytes);
                        if (count_end > bytes.len) return .{ .incomplete = .{
                            .property_index = property_index,
                            .stage = .list_count,
                            .required_total = count_end,
                        } };

                        const count = list_count.decodeListCount(l.count_type, self.endian, bytes[self.offset..count_end]) catch |err| switch (err) {
                            error.InsufficientBytes => return error.InvalidLayout, // checked above
                            error.NegativeListCount => return error.NegativeListCount,
                            error.CountOverflow => return error.CountOverflow,
                        };
                        if (count > self.limits.max_list_items_per_record) return error.ListTooLarge;
                        const payload_bytes = std.math.mul(usize, count, l.item_width) catch return error.SizeOverflow;
                        const payload_end = try checkedEnd(count_end, payload_bytes, self.limits.max_record_bytes);
                        self.total_list_items = std.math.add(usize, self.total_list_items, count) catch return error.SizeOverflow;
                        if (self.counts_out) |counts| counts[property_index] = count;
                        self.list_count = count;
                        self.list_payload_end = payload_end;
                        self.offset = count_end;
                        self.in_list_payload = true;
                    }

                    if (self.list_payload_end > bytes.len) return .{ .incomplete = .{
                        .property_index = property_index,
                        .stage = .list_items,
                        .required_total = self.list_payload_end,
                    } };
                    self.offset = self.list_payload_end;
                    self.in_list_payload = false;
                    self.list_count = 0;
                    self.property_index += 1;
                },
            }
        }
        if (self.offset < self.layout.minimum_record_size) return error.InvalidLayout;
        return .{ .complete = .{
            .byte_length = self.offset,
            .total_list_items = self.total_list_items,
        } };
    }
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
    var scanner = try Scanner.init(layout, endian, limits, counts_out);
    scanner.reset();
    return scanner.scan(bytes);
}

fn checkedEnd(start: usize, width: usize, max_record_bytes: usize) ScanError!usize {
    const end = std.math.add(usize, start, width) catch return error.SizeOverflow;
    if (end > max_record_bytes) return error.RecordTooLarge;
    return end;
}
