//! Phase 9 bounded record-aligned ASCII staging. The coordinator is the only
//! owner that mutates these buffers or reads the caller's Reader.
const std = @import("std");
const reader_mod = @import("ascii_record_reader.zig");
const fault_injection = @import("../testing/fault_injection.zig");

pub const Builder = struct {
    bytes: std.ArrayList(u8) = .empty,
    offsets: std.ArrayList(usize) = .empty,
    element_index: usize = 0,
    first_record: u64 = 0,
    body_offset: u64 = 0,
    first_line_number: u64 = 0,
    record_count: usize = 0,

    pub fn deinit(self: *Builder, a: std.mem.Allocator) void {
        self.bytes.deinit(a);
        self.offsets.deinit(a);
        self.* = .{};
    }

    pub fn begin(self: *Builder, element: usize, record_index: u64, offset: u64, line_number: u64) void {
        std.debug.assert(self.record_count == 0);
        self.element_index = element;
        self.first_record = record_index;
        self.body_offset = offset;
        self.first_line_number = line_number;
    }

    /// Preserve the exact LF/CRLF spelling, so indexed offsets remain equal
    /// to source byte positions, including for split and requeued chunks.
    pub fn append(self: *Builder, a: std.mem.Allocator, view: reader_mod.RecordView, raw_length: usize) !void {
        return self.appendWithHooks(a, view, raw_length, null);
    }

    /// Test-only allocation checkpoints; all production call paths compile
    /// without callbacks or injected allocator failures.
    pub fn appendWithHooks(self: *Builder, a: std.mem.Allocator, view: reader_mod.RecordView, raw_length: usize, hooks: ?*const fault_injection.Hooks) !void {
        if (raw_length < view.bytes.len) return error.InvalidAsciiRecord;
        const delimiter_len = raw_length - view.bytes.len;
        if (delimiter_len != 1 and delimiter_len != 2) return error.InvalidAsciiRecord;
        const additional = std.math.add(usize, view.bytes.len, delimiter_len) catch return error.SizeOverflow;
        _ = std.math.add(usize, self.bytes.items.len, additional) catch return error.SizeOverflow;
        noteAllocation(hooks, .stage_raw_growth);
        try self.bytes.ensureUnusedCapacity(a, additional);
        noteAllocation(hooks, .stage_boundary_growth);
        try self.offsets.ensureUnusedCapacity(a, if (self.record_count == 0) 2 else 1);
        const old_bytes = self.bytes.items.len;
        const old_offsets = self.offsets.items.len;
        errdefer {
            self.bytes.items.len = old_bytes;
            self.offsets.items.len = old_offsets;
        }
        if (self.record_count == 0) try self.offsets.append(a, 0);
        try self.bytes.appendSlice(a, view.bytes);
        if (delimiter_len == 2) try self.bytes.append(a, '\r');
        try self.bytes.append(a, '\n');
        try self.offsets.append(a, self.bytes.items.len);
        self.record_count += 1;
    }

    fn noteAllocation(hooks: ?*const fault_injection.Hooks, point: fault_injection.AsciiAdmissionPoint) void {
        if (@import("builtin").is_test) {
            if (hooks) |h| {
                if (h.ascii_admission_point) |callback| callback(h.context, point);
            }
        }
    }

    pub fn record(self: *const Builder, i: usize) []const u8 {
        std.debug.assert(i < self.record_count);
        return self.bytes.items[self.offsets.items[i]..self.offsets.items[i + 1]];
    }

    /// Drop an admitted prefix only after the task's immutable byte and
    /// boundary copies have been prepared. No reader rewind is necessary.
    pub fn consumePrefix(self: *Builder, count: usize) void {
        std.debug.assert(count > 0 and count <= self.record_count);
        const removed = self.offsets.items[count];
        const remaining = self.record_count - count;
        std.mem.copyForwards(u8, self.bytes.items[0 .. self.bytes.items.len - removed], self.bytes.items[removed..]);
        self.bytes.items.len -= removed;
        for (0..remaining + 1) |i| self.offsets.items[i] = self.offsets.items[i + count] - removed;
        self.offsets.items.len = if (remaining == 0) 0 else remaining + 1;
        self.record_count = remaining;
        self.first_record += @intCast(count);
        self.body_offset += @intCast(removed);
        self.first_line_number += @intCast(count);
    }
};

test "builder preserves CRLF offsets after a prefix split" {
    const a = std.testing.allocator;
    var b: Builder = .{};
    defer b.deinit(a);
    b.begin(1, 5, 32, 11);
    try b.append(a, .{ .bytes = "1 2", .body_offset = 32, .line_number = 1 }, 5);
    try b.append(a, .{ .bytes = "3 4", .body_offset = 37, .line_number = 2 }, 4);
    try std.testing.expectEqualSlices(usize, &.{ 0, 5, 9 }, b.offsets.items);
    try std.testing.expectEqualStrings("1 2\r\n3 4\n", b.bytes.items);
    b.consumePrefix(1);
    try std.testing.expectEqualStrings("3 4\n", b.bytes.items);
    try std.testing.expectEqualSlices(usize, &.{ 0, 4 }, b.offsets.items);
    try std.testing.expectEqual(@as(u64, 37), b.body_offset);
    try std.testing.expectEqual(@as(u64, 6), b.first_record);
}
